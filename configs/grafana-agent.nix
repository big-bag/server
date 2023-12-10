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
      settings = let
        IP_ADDRESS = (import ./connection-parameters.nix).ip_address;
        CONTAINERS_BACKEND = config.virtualisation.oci-containers.backend;
      in {
        metrics = {
          wal_directory = "/var/lib/private/grafana-agent/wal";
          configs = [
            {
              name = "mimir";
              scrape_configs = [{
                job_name = "local/mimir";
                scrape_interval = "1m";
                scrape_timeout = "10s";
                scheme = "http";
                static_configs = [{
                  targets = [ "${IP_ADDRESS}:9009" ];
                  labels = {
                    cluster = "local";
                    namespace = "local";
                    pod = "mimir";
                  };
                }];
                metrics_path = "/mimir/metrics";
              }];
              remote_write = [{
                url = "http://${IP_ADDRESS}:9009/mimir/api/v1/push";
              }];
            }
            {
              name = "loki";
              scrape_configs = [{
                job_name = "loki";
                scrape_interval = "1m";
                scrape_timeout = "10s";
                scheme = "http";
                static_configs = [{
                  targets = [ "${IP_ADDRESS}:3100" ];
                }];
                metrics_path = "/metrics";
                metric_relabel_configs = [{
                  source_labels = [ "__name__" ];
                  regex = "(go_.*)";
                  action = "keep";
                }];
              }];
              remote_write = [{
                url = "http://${IP_ADDRESS}:9009/mimir/api/v1/push";
              }];
            }
          ];
        };

        logs = {
          configs = [
            {
              name = "system";
              clients = [{
                url = "http://${config.services.loki.configuration.server.http_listen_address}:${toString config.services.loki.configuration.server.http_listen_port}/loki/api/v1/push";
              }];
              positions = {
                filename = "/var/lib/private/grafana-agent/positions/system.yml";
              };
              scrape_configs = [{
                job_name = "journal";
                journal = {
                  json = false;
                  max_age = "12h";
                  labels = {
                    systemd_job = "systemd-journal";
                  };
                  path = "/var/log/journal";
                };
                relabel_configs = [
                  {
                    source_labels = [ "__journal__systemd_unit" ];
                    regex = "(systemd-timesyncd|sshd|${CONTAINERS_BACKEND}).service";
                    action = "keep";
                  }
                  {
                    source_labels = [ "__journal__systemd_unit" ];
                    target_label = "systemd_unit";
                    action = "replace";
                  }
                ];
              }];
            }
            {
              name = "minio";
              clients = [{
                url = "http://${config.services.loki.configuration.server.http_listen_address}:${toString config.services.loki.configuration.server.http_listen_port}/loki/api/v1/push";
              }];
              positions = {
                filename = "/var/lib/private/grafana-agent/positions/minio.yml";
              };
              scrape_configs = [{
                job_name = "journal";
                journal = {
                  json = false;
                  max_age = "12h";
                  labels = {
                    systemd_job = "systemd-journal";
                  };
                  path = "/var/log/journal";
                };
                relabel_configs = [
                  {
                    source_labels = [ "__journal__systemd_unit" ];
                    regex = "(${CONTAINERS_BACKEND}-minio|minio-1password).service";
                    action = "keep";
                  }
                  {
                    source_labels = [ "__journal__systemd_unit" ];
                    target_label = "systemd_unit";
                    action = "replace";
                  }
                ];
              }];
            }
            {
              name = "mimir";
              clients = [{
                url = "http://${config.services.loki.configuration.server.http_listen_address}:${toString config.services.loki.configuration.server.http_listen_port}/loki/api/v1/push";
              }];
              positions = {
                filename = "/var/lib/private/grafana-agent/positions/mimir.yml";
              };
              scrape_configs = [{
                job_name = "journal";
                journal = {
                  json = false;
                  max_age = "12h";
                  labels = {
                    systemd_job = "systemd-journal";
                  };
                  path = "/var/log/journal";
                };
                relabel_configs = [
                  {
                    source_labels = [ "__journal__systemd_unit" ];
                    regex = "(mimir-prepare|var-lib-private-mimir|mimir-minio|mimir|mimir-1password).(service|mount)";
                    action = "keep";
                  }
                  {
                    source_labels = [ "__journal__systemd_unit" ];
                    target_label = "systemd_unit";
                    action = "replace";
                  }
                ];
              }];
            }
            {
              name = "loki";
              clients = [{
                url = "http://${config.services.loki.configuration.server.http_listen_address}:${toString config.services.loki.configuration.server.http_listen_port}/loki/api/v1/push";
              }];
              positions = {
                filename = "/var/lib/private/grafana-agent/positions/loki.yml";
              };
              scrape_configs = [{
                job_name = "journal";
                journal = {
                  json = false;
                  max_age = "12h";
                  labels = {
                    systemd_job = "systemd-journal";
                  };
                  path = "/var/log/journal";
                };
                relabel_configs = [
                  {
                    source_labels = [ "__journal__systemd_unit" ];
                    regex = "(loki-prepare|loki-minio|loki|loki-1password).service";
                    action = "keep";
                  }
                  {
                    source_labels = [ "__journal__systemd_unit" ];
                    target_label = "systemd_unit";
                    action = "replace";
                  }
                ];
              }];
            }
            {
              name = "grafana-agent";
              clients = [{
                url = "http://${config.services.loki.configuration.server.http_listen_address}:${toString config.services.loki.configuration.server.http_listen_port}/loki/api/v1/push";
              }];
              positions = {
                filename = "/var/lib/private/grafana-agent/positions/grafana-agent.yml";
              };
              scrape_configs = [{
                job_name = "journal";
                journal = {
                  json = false;
                  max_age = "12h";
                  labels = {
                    systemd_job = "systemd-journal";
                  };
                  path = "/var/log/journal";
                };
                relabel_configs = [
                  {
                    source_labels = [ "__journal__systemd_unit" ];
                    regex = "(grafana-agent-prepare|var-lib-private-grafana\\x2dagent|grafana-agent).(service|mount)";
                    action = "keep";
                  }
                  {
                    source_labels = [ "__journal__systemd_unit" ];
                    target_label = "systemd_unit";
                    action = "replace";
                  }
                ];
              }];
            }
          ];
        };

        integrations = {
          agent = {
            enabled = true;
            scrape_integration = true;
            scrape_interval = "1m";
            scrape_timeout = "10s";
            metric_relabel_configs = [{
              source_labels = [ "__name__" ];
              regex = "(go_.*)";
              action = "keep";
            }];
          };
          prometheus_remote_write = [{
            url = "http://${IP_ADDRESS}:9009/mimir/api/v1/push";
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
