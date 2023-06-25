{ config, pkgs, ... }:

{
  systemd.services = {
    grafana-agent-prepare = {
      before = [ "var-lib-private-grafana\\x2dagent.mount" ];
      serviceConfig = {
        Type = "oneshot";
      };
      script = "${pkgs.coreutils}/bin/mkdir -p /mnt/ssd/monitoring";
      wantedBy = [ "var-lib-private-grafana\\x2dagent.mount" ];
    };
  };

  fileSystems."/var/lib/private/grafana-agent" = {
    device = "/mnt/ssd/monitoring/grafana-agent";
    options = [
      "bind"
      "x-systemd.before=grafana-agent.service"
      "x-systemd.wanted-by=grafana-agent.service"
    ];
  };

  services = {
    grafana-agent = {
      enable = true;
      settings = {
        metrics = {
          global = {
            scrape_interval = "1m";
            scrape_timeout = "10s";
          };
          wal_directory = "/var/lib/private/grafana-agent/wal";
          configs = [{
            name = "agent";
            scrape_configs = [
              {
                job_name = "local/mimir";
                scheme = "http";
                static_configs = [{
                  targets = [ "${toString config.services.mimir.configuration.server.http_listen_address}:${toString config.services.mimir.configuration.server.http_listen_port}" ];
                  labels = {
                    cluster = "local";
                    namespace = "local";
                    pod = "mimir";
                  };
                }];
                metrics_path = "/mimir/metrics";
                scrape_interval = "5s";
              }
              {
                job_name = "grafana";
                scheme = "http";
                static_configs = [{
                  targets = [ "${toString config.services.grafana.settings.server.http_addr}:${toString config.services.grafana.settings.server.http_port}" ];
                }];
                metrics_path = "/metrics";
              }
            ];
            remote_write = [{
              url = "http://${toString config.services.mimir.configuration.server.http_listen_address}:${toString config.services.mimir.configuration.server.http_listen_port}/mimir/api/v1/push";
            }];
          }];
        };

        logs = {
          positions_directory = "/var/lib/private/grafana-agent/positions";
          configs = [{
            name = "agent";
            clients = [{
              url = "http://${toString config.services.loki.configuration.server.http_listen_address}:${toString config.services.loki.configuration.server.http_listen_port}/loki/api/v1/push";
            }];
            scrape_configs = [{
              job_name = "journal";
              journal = {
                json = false;
                max_age = "12h";
                labels = {
                  job = "systemd-journal";
                };
                path = "/var/log/journal";
              };
              relabel_configs = [{
                source_labels = ["__journal__systemd_unit"];
                target_label = "unit";
              }];
            }];
          }];
        };

        integrations = {
          agent = {
            scrape_integration = false;
          };
          node_exporter = {
            enabled = true;
            scrape_interval = "2s";
          };
          prometheus_remote_write = [{
            url = "http://${toString config.services.mimir.configuration.server.http_listen_address}:${toString config.services.mimir.configuration.server.http_listen_port}/mimir/api/v1/push";
          }];
        };
      };
    };
  };

  systemd.services = {
    grafana-agent = {
      serviceConfig = {
        CPUQuota = "6%";
        MemoryHigh = "1946M";
        MemoryMax = "2048M";
      };
    };
  };
}
