{ config, pkgs, ... }:

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

  systemd.services = {
    loki-minio = {
      before = [ "loki.service" ];
      serviceConfig = let
        CONTAINERS_BACKEND = "${config.virtualisation.oci-containers.backend}";
        ENTRYPOINT = pkgs.writeTextFile {
          name = "entrypoint.sh";
          text = ''
            #!/bin/bash

            mc alias set $ALIAS http://${toString config.services.minio.listenAddress} $MINIO_ACCESS_KEY $MINIO_SECRET_KEY

            mc mb --ignore-existing $ALIAS/loki
            mc anonymous set public $ALIAS/loki
          '';
          executable = true;
        };
        MINIO_CLIENT_IMAGE = (import /etc/nixos/variables.nix).minio_client_image;
      in {
        Type = "oneshot";
        EnvironmentFile = pkgs.writeTextFile {
          name = ".env";
          text = ''
            ALIAS = local
            MINIO_ACCESS_KEY = {{ minio_access_key }}
            MINIO_SECRET_KEY = {{ minio_secret_key }}
          '';
        };
        ExecStart = ''${pkgs.bash}/bin/bash -c ' \
          ${pkgs.${CONTAINERS_BACKEND}}/bin/${CONTAINERS_BACKEND} run \
            --rm \
            --name loki-minio \
            --volume ${ENTRYPOINT}:/entrypoint.sh \
            --env ALIAS=$ALIAS \
            --env MINIO_ACCESS_KEY=$MINIO_ACCESS_KEY \
            --env MINIO_SECRET_KEY=$MINIO_SECRET_KEY \
            --entrypoint /entrypoint.sh \
            --cpus 0.03125 \
            --memory-reservation 122m \
            --memory 128m \
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
      extraFlags = [ "-log-config-reverse-order" ];
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
            dir = "${config.services.loki.dataDir}/wal";
          };
        };
        storage_config = {
          aws = {
            s3forcepathstyle = true;
            bucketnames = "loki";
            endpoint = "http://${toString config.services.minio.listenAddress}";
            region = "${toString config.services.minio.region}";
            access_key_id = "{{ minio_access_key }}";
            secret_access_key = "{{ minio_secret_key }}";
            insecure = true;
          };
          boltdb_shipper = {
            active_index_directory = "${config.services.loki.dataDir}/index";
            shared_store = "s3";
            cache_location = "${config.services.loki.dataDir}/cache";
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
          working_directory = "${config.services.loki.dataDir}/compactor";
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
        StartLimitBurst = 0;
        CPUQuota = "2%";
        MemoryHigh = "486M";
        MemoryMax = "512M";
      };
    };
  };
}
