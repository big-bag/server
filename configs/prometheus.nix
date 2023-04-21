{ config, ... }:

{
  fileSystems."/var/lib/prometheus2" = {
    device = "/mnt/ssd/monitoring/prometheus2";
    options = [ "bind" ];
  };

  services = {
    prometheus = {
      enable = true;
      listenAddress = "127.0.0.1";
      port = 9090;
      webExternalUrl = "http://{{ internal_domain_name }}/prometheus";
      stateDir = "prometheus2";
      retentionTime = "15d";
      checkConfig = "syntax-only";
      enableReload = true;
      globalConfig = {
        scrape_interval = "1m";
        scrape_timeout = "10s";
        evaluation_interval = "1m";
      };
      scrapeConfigs = [
        {
          job_name = "minio-job";
          scheme = "http";
          static_configs = [{
            targets = [ "${toString config.services.minio.listenAddress}" ];
          }];
          metrics_path = "/minio/v2/metrics/cluster";
          bearer_token_file = "/mnt/ssd/monitoring/.minioScrapeBearerToken";
        }
        {
          job_name = "prometheus";
          scheme = "http";
          static_configs = [{
            targets = [ "127.0.0.1:${toString config.services.prometheus.port}" ];
          }];
          metrics_path = "/prometheus/metrics";
        }
      ];
      remoteWrite = [{
        url = "http://127.0.0.1:${toString config.services.mimir.configuration.server.http_listen_port}/mimir/api/v1/push";
        write_relabel_configs = [{
          source_labels = [
            "__name__"
            "instance"
            "job"
          ];
          regex = ".*;127.0.0.1:${toString config.services.prometheus.port};prometheus";
          action = "drop";
        }];
      }];
    };
  };

  services = {
    nginx = {
      virtualHosts."{{ internal_domain_name }}" = {
        locations."/prometheus" = {
          proxyPass = "http://127.0.0.1:${toString config.services.prometheus.port}";
          basicAuth = { {{ prometheus_username }} = "{{ prometheus_password }}"; };
        };
      };
    };
  };

  virtualisation = {
    oci-containers = {
      containers = {
        op-prometheus = {
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

              op item get 'Prometheus (generated)' \\
                --vault 'Local server' \\
                --session $SESSION_TOKEN

              if [ $? != 0 ]; then
                op item template get Login --session $SESSION_TOKEN | op item create --vault 'Local server' - \\
                  --title 'Prometheus (generated)' \\
                  --url http://{{ internal_domain_name }}/prometheus \\
                  username={{ prometheus_username }} \\
                  password='{{ prometheus_password }}' \\
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
      prometheus = {
        serviceConfig = {
          CPUQuota = "0,39%";
          MemoryHigh = "115M";
          MemoryMax = "128M";
        };
      };

      podman-op-prometheus = {
        serviceConfig = {
          RestartPreventExitStatus = 0;
        };
      };
    };
  };
}
