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

  services = {
    nginx = {
      virtualHosts."{{ internal_domain_name }}" = {
        locations."/mimir/" = {
          proxyPass = "http://127.0.0.1:${toString config.services.mimir.configuration.server.http_listen_port}";
          basicAuth = { {{ mimir_username }} = "{{ mimir_password }}"; };
        };
      };
    };
  };

  virtualisation = {
    oci-containers = {
      containers = {
        op-mimir = {
          image = "1password/op:2.16.1";
          autoStart = true;
          extraOptions = [
            "--cpus=0.01563"
            "--memory-reservation=58m"
            "--memory=64m"
          ];
          environment = { OP_DEVICE = "{{ hostvars['localhost']['vault_1password_device_id'] }}"; };
          entrypoint = "/bin/bash";
          cmd = [
            "-c" "
              SESSION_TOKEN=$(echo {{ hostvars['localhost']['vault_1password_master_password'] }} | op account add \\
                --address {{ hostvars['localhost']['vault_1password_subdomain'] }}.1password.com \\
                --email {{ hostvars['localhost']['vault_1password_email_address'] }} \\
                --secret-key {{ hostvars['localhost']['vault_1password_secret_key'] }} \\
                --signin --raw)

              op item get 'Mimir (generated)' \\
                --vault 'Local server' \\
                --session $SESSION_TOKEN

              if [ $? != 0 ]; then
                op item template get Login --session $SESSION_TOKEN | op item create --vault 'Local server' - \\
                  --title 'Mimir (generated)' \\
                  --url http://{{ internal_domain_name }}/mimir \\
                  username={{ mimir_username }} \\
                  password='{{ mimir_password }}' \\
                  --session $SESSION_TOKEN
              fi
            "
          ];
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

      podman-op-mimir = {
        serviceConfig = {
          RestartPreventExitStatus = 0;
        };
      };
    };
  };
}
