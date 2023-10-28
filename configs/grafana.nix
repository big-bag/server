{ config, pkgs, ... }:

let
  DOMAIN_NAME_INTERNAL = (import ./connection-parameters.nix).domain_name_internal;
in

{
  systemd.services = {
    grafana-prepare = {
      before = [ "grafana.service" ];
      serviceConfig = {
        Type = "oneshot";
      };
      script = "${pkgs.coreutils}/bin/mkdir -p /mnt/ssd/monitoring";
      wantedBy = [ "grafana.service" ];
    };
  };

  sops.secrets = {
    "grafana/application/envs" = {
      mode = "0400";
      owner = config.users.users.root.name;
      group = config.users.users.root.group;
    };
  };

  services = {
    grafana = {
      enable = true;
      dataDir = "/mnt/ssd/monitoring/grafana";
      settings = {
        server = {
          protocol = "http";
          http_addr = "127.0.0.1";
          http_port = 3000;
          domain = "${DOMAIN_NAME_INTERNAL}";
          root_url = "%(protocol)s://%(domain)s:%(http_port)s/grafana/";
          enable_gzip = true;
        };
        security = {
          admin_user = "$__env{GRAFANA_USERNAME}";
          admin_password = "$__env{GRAFANA_PASSWORD}";
        };
      };
      provision = {
        enable = true;
        datasources.path = pkgs.writeTextFile {
          name = "datasources.yml";
          text = ''
            apiVersion: 1

            datasources:
              - name: Mimir
                type: prometheus
                access: proxy
                orgId: 1
                uid: $GRAFANA_DATASOURCE_UID_MIMIR
                url: http://127.0.0.1:9009/mimir/prometheus
                isDefault: false
                jsonData:
                  manageAlerts: true
                  timeInterval: 1m # 'Scrape interval' in Grafana UI, defaults to 15s
                  httpMethod: POST
                  prometheusType: Mimir
                editable: true

              - name: Prometheus
                type: prometheus
                access: proxy
                orgId: 1
                uid: $GRAFANA_DATASOURCE_UID_PROMETHEUS
                url: http://${config.services.prometheus.listenAddress}:${toString config.services.prometheus.port}/prometheus
                isDefault: false
                jsonData:
                  manageAlerts: true
                  timeInterval: ${config.services.prometheus.globalConfig.scrape_interval} # 'Scrape interval' in Grafana UI, defaults to 15s
                  httpMethod: POST
                  prometheusType: Prometheus
                editable: true

              - name: Loki
                type: loki
                access: proxy
                orgId: 1
                uid: $GRAFANA_DATASOURCE_UID_LOKI
                url: http://${config.services.loki.configuration.server.http_listen_address}:${toString config.services.loki.configuration.server.http_listen_port}
                isDefault: true
                jsonData:
                  manageAlerts: true
                  maxLines: 1000
                editable: true
          '';
        };
        dashboards.path = pkgs.writeTextFile {
          name = "dashboards.yml";
          text = ''
            apiVersion: 1

            providers:
              - name: Dashboards
                orgId: 1
                type: file
                disableDeletion: true
                updateIntervalSeconds: 30
                allowUiUpdates: true
                options:
                  path: /mnt/ssd/monitoring/grafana-dashboards
                  foldersFromFilesStructure: true
          '';
        };
      };
    };
  };

  systemd.services = {
    grafana = {
      serviceConfig = {
        EnvironmentFile = config.sops.secrets."grafana/application/envs".path;
        CPUQuota = "6%";
        MemoryHigh = "1946M";
        MemoryMax = "2048M";
      };
    };
  };

  services = {
    nginx = {
      upstreams."grafana" = {
        servers = let
          GRAFANA_ADDRESS = "${config.services.grafana.settings.server.http_addr}:${toString config.services.grafana.settings.server.http_port}";
        in { "${GRAFANA_ADDRESS}" = {}; };
      };

      virtualHosts.${DOMAIN_NAME_INTERNAL} = {
        locations."/grafana/" = {
          extraConfig = ''
            rewrite ^/grafana/(.*) /$1 break;
            proxy_set_header Host $host;
          '';
          proxyPass = "http://grafana";
        };

        # Proxy Grafana Live WebSocket connections.
        locations."/grafana/api/live/" = {
          extraConfig = ''
            rewrite ^/grafana/(.*) /$1 break;
            proxy_http_version 1.1;

            proxy_set_header Upgrade    $http_upgrade;
            proxy_set_header Connection $connection_upgrade;
            proxy_set_header Host       $host;
          '';
          proxyPass = "http://grafana";
        };
      };
    };
  };

  sops.secrets = {
    "1password/application/envs" = {
      mode = "0400";
      owner = config.users.users.root.name;
      group = config.users.users.root.group;
    };
  };

  systemd.services = {
    grafana-1password = {
      after = [ "grafana.service" ];
      preStart = "${pkgs.coreutils}/bin/sleep $((RANDOM % 24))";
      serviceConfig = {
        Type = "oneshot";
        EnvironmentFile = [
          config.sops.secrets."1password/application/envs".path
          config.sops.secrets."grafana/application/envs".path
        ];
      };
      environment = {
        OP_CONFIG_DIR = "~/.config/op";
      };
      script = ''
        set +e

        SESSION_TOKEN=$(echo "$OP_MASTER_PASSWORD" | ${pkgs._1password}/bin/op account add \
          --address $OP_SUBDOMAIN.1password.com \
          --email $OP_EMAIL_ADDRESS \
          --secret-key $OP_SECRET_KEY \
          --signin --raw)

        ${pkgs._1password}/bin/op item get Grafana \
          --vault Server \
          --session $SESSION_TOKEN > /dev/null

        if [ $? != 0 ]
        then
          ${pkgs._1password}/bin/op item template get Login --session $SESSION_TOKEN | ${pkgs._1password}/bin/op item create --vault Server - \
            --title Grafana \
            --url http://${DOMAIN_NAME_INTERNAL}/grafana \
            username=$GRAFANA_USERNAME \
            password=$GRAFANA_PASSWORD \
            --session $SESSION_TOKEN > /dev/null

          ${pkgs.coreutils}/bin/echo "Item created successfully."
        else
          ${pkgs._1password}/bin/op item edit Grafana \
            --vault Server \
            --url http://${DOMAIN_NAME_INTERNAL}/grafana \
            username=$GRAFANA_USERNAME \
            password=$GRAFANA_PASSWORD \
            --session $SESSION_TOKEN > /dev/null

          ${pkgs.coreutils}/bin/echo "Item edited successfully."
        fi
      '';
      wantedBy = [ "grafana.service" ];
    };
  };

  services = {
    grafana-agent = {
      settings = {
        metrics = {
          configs = [{
            name = "grafana";
            scrape_configs = [{
              job_name = "grafana";
              scrape_interval = "1m";
              scrape_timeout = "10s";
              scheme = "http";
              static_configs = [{
                targets = [ "${config.services.grafana.settings.server.http_addr}:${toString config.services.grafana.settings.server.http_port}" ];
              }];
              metrics_path = "/metrics";
            }];
            remote_write = [{
              url = "http://127.0.0.1:9009/mimir/api/v1/push";
            }];
          }];
        };

        logs = {
          configs = [{
            name = "grafana";
            clients = [{
              url = "http://${config.services.loki.configuration.server.http_listen_address}:${toString config.services.loki.configuration.server.http_listen_port}/loki/api/v1/push";
            }];
            positions = {
              filename = "/var/lib/private/grafana-agent/positions/grafana.yml";
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
              relabel_configs = [
                {
                  source_labels = [ "__journal__systemd_unit" ];
                  regex = "(grafana-prepare|grafana|grafana-1password).service";
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
      };
    };
  };
}
