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
    "minio/application/envs" = {
      mode = "0400";
      owner = config.users.users.root.name;
      group = config.users.users.root.group;
    };
  };

  sops.secrets = {
    "mimir/minio/envs" = {
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
        EnvironmentFile = [
          config.sops.secrets."minio/application/envs".path
          config.sops.secrets."mimir/minio/envs".path
        ];
      };
      environment = {
        ALIAS = "local";
      };
      path = [ pkgs.getent ];
      script = let
        policy_json = pkgs.writeTextFile {
          name = "policy.json";
          text = ''
            {
                "Version": "2012-10-17",
                "Statement": [
                    {
                        "Effect": "Allow",
                        "Action": "s3:ListBucket",
                        "Resource": [
                            "arn:aws:s3:::mimir-blocks",
                            "arn:aws:s3:::mimir-ruler",
                            "arn:aws:s3:::mimir-alertmanager"
                        ]
                    },
                    {
                        "Effect": "Allow",
                        "Action": [
                            "s3:PutObject",
                            "s3:GetObject",
                            "s3:DeleteObject"
                        ],
                        "Resource": [
                            "arn:aws:s3:::mimir-blocks/*",
                            "arn:aws:s3:::mimir-ruler/*",
                            "arn:aws:s3:::mimir-alertmanager/*"
                        ]
                    }
                ]
            }
          '';
        };
      in ''
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
            ${pkgs.minio-client}/bin/mc alias set $ALIAS http://${IP_ADDRESS}:9000 $MINIO_ROOT_USER $MINIO_ROOT_PASSWORD

            ${pkgs.minio-client}/bin/mc mb --ignore-existing $ALIAS/mimir-blocks
            ${pkgs.minio-client}/bin/mc mb --ignore-existing $ALIAS/mimir-ruler
            ${pkgs.minio-client}/bin/mc mb --ignore-existing $ALIAS/mimir-alertmanager

            ${pkgs.minio-client}/bin/mc admin user svcacct info $ALIAS $MINIO_SERVICE_ACCOUNT_ACCESS_KEY

            if [ $? != 0 ]
            then
              ${pkgs.minio-client}/bin/mc admin user svcacct add \
                --access-key $MINIO_SERVICE_ACCOUNT_ACCESS_KEY \
                --secret-key $MINIO_SERVICE_ACCOUNT_SECRET_KEY \
                --policy ${policy_json} \
                --comment mimir \
                $ALIAS \
                $MINIO_ROOT_USER > /dev/null
              ${pkgs.coreutils}/bin/echo "Service account created successfully \`$MINIO_SERVICE_ACCOUNT_ACCESS_KEY\`."
            else
              ${pkgs.minio-client}/bin/mc admin user svcacct edit \
                --secret-key $MINIO_SERVICE_ACCOUNT_SECRET_KEY \
                --policy ${policy_json} \
                $ALIAS \
                $MINIO_SERVICE_ACCOUNT_ACCESS_KEY
              ${pkgs.coreutils}/bin/echo "Service account updated successfully \`$MINIO_SERVICE_ACCOUNT_ACCESS_KEY\`."
            fi

            break
          fi
          ${pkgs.coreutils}/bin/echo "Waiting for MinIO availability."
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
                secret_access_key: ''${MINIO_SERVICE_ACCOUNT_SECRET_KEY}
                access_key_id: ''${MINIO_SERVICE_ACCOUNT_ACCESS_KEY}
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
        EnvironmentFile = config.sops.secrets."mimir/minio/envs".path;
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
    "mimir/nginx/file/basic_auth" = {
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
          basicAuthFile = config.sops.secrets."mimir/nginx/file/basic_auth".path;
        };
      };
    };
  };

  sops.secrets = {
    "1password/application/envs" = {
      mode = "0400";
      owner = config.users.users.root.name;
      group = config.users.users.root.group;
    };
  };

  sops.secrets = {
    "mimir/nginx/envs" = {
      mode = "0400";
      owner = config.users.users.root.name;
      group = config.users.users.root.group;
    };
  };

  systemd.services = {
    mimir-1password = {
      after = [ "mimir.service" ];
      preStart = "${pkgs.coreutils}/bin/sleep $((RANDOM % 33))";
      serviceConfig = {
        Type = "oneshot";
        EnvironmentFile = [
          config.sops.secrets."1password/application/envs".path
          config.sops.secrets."mimir/nginx/envs".path
          config.sops.secrets."mimir/minio/envs".path
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
          --vault Server \
          --session $SESSION_TOKEN > /dev/null

        if [ $? != 0 ]
        then
          ${pkgs._1password}/bin/op item template get Login --session $SESSION_TOKEN | ${pkgs._1password}/bin/op item create --vault Server - \
            --title Mimir \
            --url https://${DOMAIN_NAME_INTERNAL}/mimir \
            username=$NGINX_USERNAME \
            password=$NGINX_PASSWORD \
            MinIO.'Access Key'[text]=$MINIO_SERVICE_ACCOUNT_ACCESS_KEY \
            MinIO.'Secret Key'[password]=$MINIO_SERVICE_ACCOUNT_SECRET_KEY \
            --session $SESSION_TOKEN > /dev/null
          ${pkgs.coreutils}/bin/echo "Item created successfully."
        else
          ${pkgs._1password}/bin/op item edit Mimir \
            --vault Server \
            --url https://${DOMAIN_NAME_INTERNAL}/mimir \
            username=$NGINX_USERNAME \
            password=$NGINX_PASSWORD \
            MinIO.'Access Key'[text]=$MINIO_SERVICE_ACCOUNT_ACCESS_KEY \
            MinIO.'Secret Key'[password]=$MINIO_SERVICE_ACCOUNT_SECRET_KEY \
            --session $SESSION_TOKEN > /dev/null
          ${pkgs.coreutils}/bin/echo "Item updated successfully."
        fi
      '';
      wantedBy = [ "mimir.service" ];
    };
  };
}
