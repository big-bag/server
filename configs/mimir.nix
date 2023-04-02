{ config, ... }:

{
  fileSystems."/var/lib/private/mimir" = {
    device = "/mnt/ssd/monitoring/mimir";
    options = [
      "bind"
      "x-systemd.before=mimir.service"
    ];
  };

  services = {
    mimir = {
      enable = true;
      configuration = {
        multitenancy_enabled = false;
        server = {
          http_listen_address = "127.0.0.1";
          http_listen_port = 9009;
          grpc_listen_address = "127.0.0.1";
          grpc_listen_port = 9095;
          http_path_prefix = "/mimir/";
        };
        ingester = {
          ring = {
            replication_factor = 1;
            instance_addr = "127.0.0.1";
          };
        };
        blocks_storage = {
          s3 = {
            bucket_name = "mimir-blocks";
          };
          bucket_store = {
            sync_dir = "./tsdb-sync/";
          };
          tsdb = {
            dir = "./tsdb/";
          };
        };
        compactor = {
          data_dir = "./data-compactor/";
        };
        store_gateway = {
          sharding_ring = {
            replication_factor = 1;
            instance_addr = "127.0.0.1";
          };
        };
        activity_tracker = {
          filepath = "./metrics-activity.log";
        };
        ruler = {
          rule_path = "./data-ruler/";
        };
        ruler_storage = {
          s3 = {
            bucket_name = "mimir-ruler";
          };
        };
        alertmanager = {
          data_dir = "./data-alertmanager/";
          sharding_ring = {
            replication_factor = 1;
          };
        };
        alertmanager_storage = {
          s3 = {
            bucket_name = "mimir-alertmanager";
          };
        };
        memberlist = {
          message_history_buffer_bytes = 10240;
          bind_addr = [ "127.0.0.1" ];
        };
        common.storage = {
          backend = "s3";
          s3 = {
            endpoint = "${toString config.services.minio.listenAddress}";
            region = "${toString config.services.minio.region}";
            secret_access_key = "{{ minio_secret_key }}";
            access_key_id = "{{ minio_access_key }}";
            insecure = true;
          };
        };
      };
    };
  };

  systemd = {
    services = {
      mimir = {
        serviceConfig = {
          StartLimitBurst = 0;
          CPUQuota = "0,78%";
          MemoryHigh = "230M";
          MemoryMax = "256M";
        };
      };
    };
  };

  services = {
    nginx = {
      virtualHosts."{{ internal_domain_name }}" = {
        locations."/mimir/" = {
          proxyPass     = "http://127.0.0.1:${toString config.services.mimir.configuration.server.http_listen_port}";
          basicAuthFile = /mnt/ssd/services/.mimirBasicAuthPassword;
        };
      };
    };
  };
}
