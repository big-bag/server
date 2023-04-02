{ config, ... }:

{
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

  systemd = {
    services = {
      loki = {
        serviceConfig = {
          StartLimitBurst = 0;
          CPUQuota = "0,39%";
          MemoryHigh = "115M";
          MemoryMax = "128M";
        };
      };
    };
  };
}
