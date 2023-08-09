{ config, pkgs, lib, ... }:

let
  MINIO_ENDPOINT = config.services.minio.listenAddress;
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
    "minio/envs" = {
      mode = "0400";
      owner = config.users.users.root.name;
      group = config.users.users.root.group;
    };
  };

  systemd.services = {
    loki-minio = {
      before = [ "loki.service" ];
      serviceConfig = let
        CONTAINERS_BACKEND = config.virtualisation.oci-containers.backend;
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

                mc mb --ignore-existing $ALIAS/loki

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
            --name loki-minio \
            --volume ${entrypoint}:/entrypoint.sh \
            --env-file ${config.sops.secrets."minio/envs".path} \
            --env ALIAS=local \
            --entrypoint /entrypoint.sh \
            ${MINIO_CLIENT_IMAGE}'
        '';
      };
      wantedBy = [ "loki.service" ];
    };
  };

  services = {
    loki = {
      enable = true;
      dataDir = "/mnt/ssd/monitoring/loki";
      extraFlags = [
        "-log-config-reverse-order"
        "-config.expand-env=true"
      ];
      configuration = {
        auth_enabled = false;
        server = {
          http_listen_address = "127.0.0.1";
          http_listen_port = 3100;
          grpc_listen_address = "0.0.0.0";
          grpc_listen_port = 9096;
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
            bucketnames = "loki";
            endpoint = "http://${MINIO_ENDPOINT}";
            region = config.services.minio.region;
            access_key_id = "\${MINIO_ROOT_USER}";
            secret_access_key = "\${MINIO_ROOT_PASSWORD}";
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
        };
        limits_config = {
          enforce_metric_name = false;
        };
      };
    };
  };

  systemd.services = {
    loki = {
      serviceConfig = {
        EnvironmentFile = config.sops.secrets."minio/envs".path;
        StartLimitBurst = 0;
        CPUQuota = "2%";
        MemoryHigh = "486M";
        MemoryMax = "512M";
      };
    };
  };
}
