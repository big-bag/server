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
          wal_directory = "/var/lib/private/grafana-agent/wal";
          configs = [{
            name = "mimir";
            scrape_configs = [{
              job_name = "local/mimir";
              scrape_interval = "5s";
              scrape_timeout = "5s";
              scheme = "http";
              static_configs = [{
                targets = [ "127.0.0.1:9009" ];
                labels = {
                  cluster = "local";
                  namespace = "local";
                  pod = "mimir";
                };
              }];
              metrics_path = "/mimir/metrics";
            }];
            remote_write = [{
              url = "http://127.0.0.1:9009/mimir/api/v1/push";
            }];
          }];
        };

        logs = {
          configs = [{
            name = "agent";
            clients = [{
              url = "http://${config.services.loki.configuration.server.http_listen_address}:${toString config.services.loki.configuration.server.http_listen_port}/loki/api/v1/push";
            }];
            positions = {
              filename = "/var/lib/private/grafana-agent/positions/agent.yml";
            };
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
              relabel_configs = let
                CONTAINERS_BACKEND = config.virtualisation.oci-containers.backend;
              in [
                {
                  source_labels = [ "__journal__systemd_unit" ];
                  regex = "(systemd-timesyncd|sshd|nginx-prepare|nginx|${CONTAINERS_BACKEND}|minio-prepare|${CONTAINERS_BACKEND}-minio|minio-1password|mimir-prepare|var-lib-private-mimir|mimir-minio|mimir|mimir-1password|prometheus-prepare|var-lib-prometheus2|prometheus-minio|prometheus|prometheus-1password|loki-prepare|loki-minio|loki|grafana-agent-prepare|var-lib-private-grafana\\x2dagent|grafana-agent).(service|mount)";
                  action = "keep";
                }
                {
                  source_labels = [ "__journal__systemd_unit" ];
                  target_label = "unit";
                  action = "replace";
                }
              ];
            }];
          }];
        };

        integrations = {
          agent = {
            scrape_integration = false;
          };
          prometheus_remote_write = [{
            url = "http://127.0.0.1:9009/mimir/api/v1/push";
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
