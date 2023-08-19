{ config, pkgs, lib, ... }:

let
  IP_ADDRESS = (import ./connection-parameters.nix).ip_address;
  MINIO_REGION = config.virtualisation.oci-containers.containers.minio.environment.MINIO_REGION;
  DOMAIN_NAME_INTERNAL = (import ./connection-parameters.nix).domain_name_internal;
in

{
  systemd.services = {
    mimir-prepare = {
      before = [ "var-lib-private-mimir.mount" ];
      serviceConfig = {
        Type = "oneshot";
      };
      script = "${pkgs.coreutils}/bin/mkdir -p /mnt/ssd/monitoring";
      wantedBy = [ "var-lib-private-mimir.mount" ];
    };
  };

  fileSystems."/var/lib/private/mimir" = {
    device = "/mnt/ssd/monitoring/mimir";
    options = [
      "bind"
      "x-systemd.before=mimir.service"
      "x-systemd.wanted-by=mimir.service"
    ];
  };

  sops.secrets = {
    "minio/envs" = {
      mode = "0400";
      owner = config.users.users.root.name;
      group = config.users.users.root.group;
    };
  };

  systemd.services = {
    mimir-minio = {
      before = [ "mimir.service" ];
      serviceConfig = {
        Type = "oneshot";
        EnvironmentFile = config.sops.secrets."minio/envs".path;
      };
      environment = {
        ALIAS = "local";
      };
      path = [ pkgs.getent ];
      script = ''
        set +e

        # args: host port
        check_port_is_open() {
          local exit_status_code
          ${pkgs.curl}/bin/curl --silent --connect-timeout 1 --telnet-option "" telnet://"$1:$2" </dev/null
          exit_status_code=$?
          case $exit_status_code in
            49) return 0 ;;
            *) return "$exit_status_code" ;;
          esac
        }

        while true; do
          check_port_is_open ${IP_ADDRESS} 9000
          if [ $? == 0 ]; then
            ${pkgs.coreutils}/bin/echo "Creating buckets in the MinIO"

            ${pkgs.minio-client}/bin/mc alias set $ALIAS http://${IP_ADDRESS}:9000 $MINIO_ROOT_USER $MINIO_ROOT_PASSWORD

            ${pkgs.minio-client}/bin/mc mb --ignore-existing $ALIAS/mimir-blocks
            ${pkgs.minio-client}/bin/mc mb --ignore-existing $ALIAS/mimir-ruler
            ${pkgs.minio-client}/bin/mc mb --ignore-existing $ALIAS/mimir-alertmanager

            break
          fi
          ${pkgs.coreutils}/bin/echo "Waiting for MinIO availability"
          ${pkgs.coreutils}/bin/sleep 1
        done
      '';
      wantedBy = [ "mimir.service" ];
    };
  };

  services = {
    mimir = let
      config = pkgs.writeTextFile {
        name = "config.yml";
        text = ''
          multitenancy_enabled: false

          server:
            http_listen_address: 127.0.0.1
            http_listen_port: 9009
            grpc_listen_address: 127.0.0.1
            grpc_listen_port: 9095
            http_path_prefix: /mimir/

          ingester:
            ring:
              replication_factor: 1
              instance_addr: 127.0.0.1

          blocks_storage:
            s3:
              bucket_name: mimir-blocks
            bucket_store:
              sync_dir: ./tsdb-sync/
            tsdb:
              dir: ./tsdb/

          compactor:
            data_dir: ./data-compactor/

          store_gateway:
            sharding_ring:
              replication_factor: 1
              instance_addr: 127.0.0.1

          activity_tracker:
            filepath: ./metrics-activity.log

          ruler:
            rule_path: ./data-ruler/

          ruler_storage:
            s3:
              bucket_name: mimir-ruler

          alertmanager:
            data_dir: ./data-alertmanager/
            sharding_ring:
              replication_factor: 1

          alertmanager_storage:
            s3:
              bucket_name: mimir-alertmanager

          memberlist:
            message_history_buffer_bytes: 10240
            bind_addr: [ 127.0.0.1 ]

          common:
            storage:
              backend: s3
              s3:
                endpoint: ${IP_ADDRESS}:9000
                region: ${MINIO_REGION}
                secret_access_key: ''${MINIO_ROOT_PASSWORD}
                access_key_id: ''${MINIO_ROOT_USER}
                insecure: true
        '';
      };
    in {
      enable = true;
      configFile = "${config}";
    };
  };

  systemd.services = {
    mimir = {
      serviceConfig = {
        EnvironmentFile = config.sops.secrets."minio/envs".path;
        ExecStart = pkgs.lib.mkForce ''
          ${pkgs.mimir}/bin/mimir \
            -config.file=${config.services.mimir.configFile} \
            -config.expand-env=true
        '';
        StartLimitBurst = 0;
        CPUQuota = "6%";
        MemoryHigh = "1946M";
        MemoryMax = "2048M";
      };
    };
  };

  sops.secrets = {
    "mimir/nginx_file" = {
      mode = "0400";
      owner = config.services.nginx.user;
      group = config.services.nginx.group;
    };
  };

  services = {
    nginx = {
      virtualHosts.${DOMAIN_NAME_INTERNAL} = {
        locations."/mimir/" = {
          proxyPass = "http://127.0.0.1:9009";
          basicAuthFile = config.sops.secrets."mimir/nginx_file".path;
        };
      };
    };
  };

  sops.secrets = {
    "1password" = {
      mode = "0400";
      owner = config.users.users.root.name;
      group = config.users.users.root.group;
    };
  };

  sops.secrets = {
    "mimir/nginx_envs" = {
      mode = "0400";
      owner = config.users.users.root.name;
      group = config.users.users.root.group;
    };
  };

  systemd.services = {
    mimir-1password = {
      after = [ "mimir.service" ];
      preStart = "${pkgs.coreutils}/bin/sleep $((RANDOM % 21))";
      serviceConfig = {
        Type = "oneshot";
        EnvironmentFile = [
          config.sops.secrets."1password".path
          config.sops.secrets."mimir/nginx_envs".path
        ];
      };
      environment = {
        OP_CONFIG_DIR = "~/.config/op";
      };
      script = ''
        set +e

        SESSION_TOKEN=$(echo "$OP_MASTER_PASSWORD" | ${pkgs._1password}/bin/op account add \
          --address $OP_SUBDOMAIN.1password.com \
          --email $OP_EMAIL_ADDRESS \
          --secret-key $OP_SECRET_KEY \
          --signin --raw)

        ${pkgs._1password}/bin/op item get Mimir \
          --vault 'Local server' \
          --session $SESSION_TOKEN > /dev/null

        if [ $? != 0 ]; then
          ${pkgs._1password}/bin/op item template get Login --session $SESSION_TOKEN | ${pkgs._1password}/bin/op item create --vault 'Local server' - \
            --title Mimir \
            --url http://${DOMAIN_NAME_INTERNAL}/mimir \
            username=$MIMIR_NGINX_USERNAME \
            password=$MIMIR_NGINX_PASSWORD \
            --session $SESSION_TOKEN > /dev/null
        fi
      '';
      wantedBy = [ "mimir.service" ];
    };
  };
}
