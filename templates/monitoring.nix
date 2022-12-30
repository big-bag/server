{ config, ... }:

{
  fileSystems."/var/lib/prometheus2" = {
    device = "/mnt/ssd/prometheus2";
    options = [ "bind" ];
  };

  services = {
    prometheus = {
      enable = true;
      listenAddress = "127.0.0.1";
      port = 9090;
      webExternalUrl = "http://{{ internal_domain_name.stdout }}/prometheus";
      stateDir = "prometheus2";
      retentionTime = "30d";
      checkConfig = true;
      enableReload = true;
      exporters = {
        node = {
          enable = true;
          listenAddress = "127.0.0.1";
          port = 9100;
          user = "node-exporter";
          group = "node-exporter";
        };
      };
      scrapeConfigs = [
        {
          job_name = "prometheus";
          scheme = "http";
          static_configs = [{
            targets = [ "127.0.0.1:${toString config.services.prometheus.port}" ];
          }];
          metrics_path = "/prometheus/metrics";
        }
        {
          job_name = "server";
          scheme = "http";
          static_configs = [{
            targets = [ "127.0.0.1:${toString config.services.prometheus.exporters.node.port}" ];
          }];
          metrics_path = "/metrics";
        }
      ];
    };

    nginx = {
      virtualHosts."{{ internal_domain_name.stdout }}" = {
        listen = [ { addr = "*"; port = 80; } ];

        locations."/prometheus" = {
          proxyPass = "http://127.0.0.1:${toString config.services.prometheus.port}";
          basicAuthFile = /root/.basicAuthPasswdFile;
        };
      };
    };
  };
}
