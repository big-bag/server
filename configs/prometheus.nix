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
          bearer_token_file = "/mnt/ssd/services/.minioScrapeBearerToken";
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

  systemd = {
    services = {
      prometheus = {
        serviceConfig = {
          CPUQuota = "0,39%";
          MemoryHigh = "115M";
          MemoryMax = "128M";
        };
      };
    };
  };

  services = {
    nginx = {
      virtualHosts."{{ internal_domain_name }}" = {
        locations."/prometheus" = {
          proxyPass     = "http://127.0.0.1:${toString config.services.prometheus.port}";
          basicAuthFile = /mnt/ssd/services/.prometheusBasicAuthPassword;
        };
      };
    };
  };
}
