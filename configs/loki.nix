{ config, pkgs, ... }:

let
  MINIO_BUCKET = "loki";
  IP_ADDRESS = (import ./connection-parameters.nix).ip_address;
in

{
  systemd.services = {
    loki-prepare = {
      before = [ "loki.service" ];
      serviceConfig = {
        Type = "oneshot";
      };
      script = "${pkgs.coreutils}/bin/mkdir -p /mnt/ssd/monitoring";
      wantedBy = [ "loki.service" ];
    };
  };

  sops.secrets = {
    "minio/application/envs" = {
      mode = "0400";
      owner = config.users.users.root.name;
      group = config.users.users.root.group;
    };
  };

  sops.secrets = {
    "loki/minio/envs" = {
      mode = "0400";
      owner = config.users.users.root.name;
      group = config.users.users.root.group;
    };
  };

  systemd.services = {
    loki-minio = {
      before = [ "loki.service" ];
      serviceConfig = {
        Type = "oneshot";
        EnvironmentFile = [
          config.sops.secrets."minio/application/envs".path
          config.sops.secrets."loki/minio/envs".path
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
                        "Resource": "arn:aws:s3:::${MINIO_BUCKET}"
                    },
                    {
                        "Effect": "Allow",
                        "Action": [
                            "s3:PutObject",
                            "s3:GetObject",
                            "s3:DeleteObject"
                        ],
                        "Resource": "arn:aws:s3:::${MINIO_BUCKET}/*"
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

        while true
        do
          check_port_is_open ${IP_ADDRESS} 9000
          if [ $? == 0 ]; then
            ${pkgs.minio-client}/bin/mc alias set $ALIAS http://${IP_ADDRESS}:9000 $MINIO_ROOT_USER $MINIO_ROOT_PASSWORD

            ${pkgs.minio-client}/bin/mc mb --ignore-existing $ALIAS/${MINIO_BUCKET}
            ${pkgs.minio-client}/bin/mc version enable $ALIAS/${MINIO_BUCKET}

            ${pkgs.minio-client}/bin/mc admin user svcacct info $ALIAS $MINIO_SERVICE_ACCOUNT_ACCESS_KEY

            if [ $? != 0 ]
            then
              ${pkgs.minio-client}/bin/mc admin user svcacct add \
                --access-key $MINIO_SERVICE_ACCOUNT_ACCESS_KEY \
                --secret-key $MINIO_SERVICE_ACCOUNT_SECRET_KEY \
                --policy ${policy_json} \
                --comment loki \
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
      wantedBy = [ "loki.service" ];
    };
  };

  services = {
    loki = {
      enable = true;
      user = "loki";
      group = "loki";
      dataDir = "/mnt/ssd/monitoring/loki";
      extraFlags = [
        "-log-config-reverse-order"
        "-config.expand-env=true"
      ];
      configuration = {
        auth_enabled = false;
        server = {
          http_listen_address = "${IP_ADDRESS}";
          http_listen_port = 3100;
          grpc_listen_address = "0.0.0.0";
          grpc_listen_port = 9096;
        };
        ruler = {
          alertmanager_url = "http://127.0.0.1:9093/alertmanager/alertmanager";
          enable_alertmanager_v2 = true;
        };
        ingester = {
          lifecycler = {
            ring = {
              kvstore = {
                store = "inmemory";
              };
              replication_factor = 1;
            };
            final_sleep = "0s";
          };
          chunk_retain_period = "30s";
          chunk_idle_period = "5m";
          wal = {
            dir = "./wal";
          };
        };
        storage_config = {
          aws = {
            s3forcepathstyle = true;
            bucketnames = "${MINIO_BUCKET}";
            endpoint = "http://${IP_ADDRESS}:9000";
            region = config.virtualisation.oci-containers.containers.minio.environment.MINIO_REGION;
            access_key_id = "\${MINIO_SERVICE_ACCOUNT_ACCESS_KEY}";
            secret_access_key = "\${MINIO_SERVICE_ACCOUNT_SECRET_KEY}";
            insecure = true;
          };
          boltdb_shipper = {
            active_index_directory = "./index";
            shared_store = "s3";
            cache_location = "./cache";
            resync_interval = "5s";
          };
        };
        schema_config = {
          configs = [{
            from = "2023-01-29";
            store = "boltdb-shipper";
            object_store = "aws";
            schema = "v11";
            index = {
              prefix = "index_";
              period = "24h";
            };
          }];
        };
        compactor = {
          working_directory = "./compactor";
          shared_store = "s3";
          retention_enabled = true;
          delete_request_cancel_period = "24h";
        };
        limits_config = {
          enforce_metric_name = false;
          deletion_mode = "filter-and-delete";
          retention_period = "0s";
        };
      };
    };
  };

  systemd.services = {
    loki = {
      serviceConfig = {
        EnvironmentFile = config.sops.secrets."loki/minio/envs".path;
        StartLimitBurst = 0;
        CPUQuota = "2%";
        MemoryHigh = "486M";
        MemoryMax = "512M";
      };
    };
  };

  networking = {
    firewall = {
      allowedTCPPorts = [ 3100 ];
    };
  };

  systemd.services = {
    loki-1password = {
      after = [ "loki.service" ];
      preStart = "${pkgs.coreutils}/bin/sleep $((RANDOM % ${(import ./variables.nix).one_password_max_delay}))";
      serviceConfig = {
        Type = "oneshot";
        EnvironmentFile = [
          config.sops.secrets."1password/application/envs".path
          config.sops.secrets."loki/minio/envs".path
        ];
      };
      environment = {
        OP_CONFIG_DIR = "/root/.config/op";
      };
      script = ''
        set +e

        SESSION_TOKEN=$(echo "$OP_MASTER_PASSWORD" | ${pkgs._1password}/bin/op account add \
          --address $OP_SUBDOMAIN.1password.com \
          --email $OP_EMAIL_ADDRESS \
          --secret-key $OP_SECRET_KEY \
          --signin --raw)

        ${pkgs._1password}/bin/op item get Loki \
          --vault Server \
          --session $SESSION_TOKEN > /dev/null

        if [ $? != 0 ]
        then
          ${pkgs._1password}/bin/op item template get Database --session $SESSION_TOKEN | ${pkgs._1password}/bin/op item create --vault Server - \
            --title Loki \
            MinIO.'Access Key'[text]=$MINIO_SERVICE_ACCOUNT_ACCESS_KEY \
            MinIO.'Secret Key'[password]=$MINIO_SERVICE_ACCOUNT_SECRET_KEY \
            --session $SESSION_TOKEN > /dev/null
          ${pkgs.coreutils}/bin/echo "Item created successfully."
        else
          ${pkgs._1password}/bin/op item edit Loki \
            --vault Server \
            MinIO.'Access Key'[text]=$MINIO_SERVICE_ACCOUNT_ACCESS_KEY \
            MinIO.'Secret Key'[password]=$MINIO_SERVICE_ACCOUNT_SECRET_KEY \
            --session $SESSION_TOKEN > /dev/null
          ${pkgs.coreutils}/bin/echo "Item updated successfully."
        fi
      '';
      wantedBy = [ "loki.service" ];
    };
  };
}
