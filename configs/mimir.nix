{ config, pkgs, lib, ... }:

let
  MINIO_ENDPOINT = config.services.minio.listenAddress;
  CONTAINERS_BACKEND = config.virtualisation.oci-containers.backend;
  MINIO_REGION = config.services.minio.region;
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
      serviceConfig = let
        entrypoint = pkgs.writeTextFile {
          name = "entrypoint.sh";
          text = ''
            #!/bin/bash

            # args: host port
            check_port_is_open() {
              local exit_status_code
              curl --silent --connect-timeout 1 --telnet-option "" telnet://"$1:$2" </dev/null
              exit_status_code=$?
              case $exit_status_code in
                49) return 0 ;;
                *) return "$exit_status_code" ;;
              esac
            }

            while true; do
              check_port_is_open ${lib.strings.stringAsChars (x: if x == ":" then " " else x) MINIO_ENDPOINT}
              if [ $? == 0 ]; then
                echo "Creating buckets in the MinIO"

                mc alias set $ALIAS http://${MINIO_ENDPOINT} $MINIO_ROOT_USER $MINIO_ROOT_PASSWORD

                mc mb --ignore-existing $ALIAS/mimir-blocks
                mc mb --ignore-existing $ALIAS/mimir-ruler
                mc mb --ignore-existing $ALIAS/mimir-alertmanager

                break
              fi
              echo "Waiting for MinIO availability"
              sleep 1
            done
          '';
          executable = true;
        };
        MINIO_CLIENT_IMAGE = (import /etc/nixos/variables.nix).minio_client_image;
      in {
        Type = "oneshot";
        ExecStart = ''${pkgs.bash}/bin/bash -c ' \
          ${pkgs.${CONTAINERS_BACKEND}}/bin/${CONTAINERS_BACKEND} run \
            --rm \
            --name mimir-minio \
            --volume ${entrypoint}:/entrypoint.sh \
            --env-file ${config.sops.secrets."minio/envs".path} \
            --env ALIAS=local \
            --entrypoint /entrypoint.sh \
            ${MINIO_CLIENT_IMAGE}'
        '';
      };
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
                endpoint: ${MINIO_ENDPOINT}
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
      serviceConfig = let
        entrypoint = pkgs.writeTextFile {
          name = "entrypoint.sh";
          text = ''
            #!/bin/bash

            SESSION_TOKEN=$(echo "$OP_MASTER_PASSWORD" | op account add \
              --address $OP_SUBDOMAIN.1password.com \
              --email $OP_EMAIL_ADDRESS \
              --secret-key $OP_SECRET_KEY \
              --signin --raw)

            op item get Mimir \
              --vault 'Local server' \
              --session $SESSION_TOKEN > /dev/null

            if [ $? != 0 ]; then
              op item template get Login --session $SESSION_TOKEN | op item create --vault 'Local server' - \
                --title Mimir \
                --url http://${DOMAIN_NAME_INTERNAL}/mimir \
                username=$MIMIR_NGINX_USERNAME \
                password=$MIMIR_NGINX_PASSWORD \
                --session $SESSION_TOKEN > /dev/null
            fi
          '';
          executable = true;
        };
        ONE_PASSWORD_IMAGE = (import /etc/nixos/variables.nix).one_password_image;
      in {
        Type = "oneshot";
        ExecStart = ''${pkgs.bash}/bin/bash -c ' \
          ${pkgs.${CONTAINERS_BACKEND}}/bin/${CONTAINERS_BACKEND} run \
            --rm \
            --name mimir-1password \
            --volume ${entrypoint}:/entrypoint.sh \
            --env-file ${config.sops.secrets."1password".path} \
            --env-file ${config.sops.secrets."mimir/nginx_envs".path} \
            --entrypoint /entrypoint.sh \
            ${ONE_PASSWORD_IMAGE}'
        '';
      };
      wantedBy = [ "mimir.service" ];
    };
  };
}
