{ config, pkgs, ... }:

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
      webExternalUrl = "http://{{ hostvars['localhost']['internal_domain_name'] }}/prometheus";
      stateDir = "prometheus2";
      retentionTime = "15d";
      checkConfig = true;
      enableReload = true;
      globalConfig = {
        scrape_interval = "1m";
        scrape_timeout = "10s";
        evaluation_interval = "1m";
      };
      exporters = {
        node = {
          enable = true;
          listenAddress = "127.0.0.1";
          port = 9100;
          user = "node-exporter";
          group = "node-exporter";
          enabledCollectors = [
            "systemd"
          ];
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
          job_name = "node";
          scheme = "http";
          static_configs = [{
            targets = [ "127.0.0.1:${toString config.services.prometheus.exporters.node.port}" ];
          }];
          metrics_path = "/metrics";
          scrape_interval = "2s";
        }
        {
          job_name = "minio-job";
          scheme = "http";
          static_configs = [{
            targets = [ "${toString config.services.minio.listenAddress}" ];
          }];
          metrics_path = "/minio/v2/metrics/cluster";
        }
        {
          job_name = "grafana";
          scheme = "http";
          static_configs = [{
            targets = [ "127.0.0.1:${toString config.services.grafana.settings.server.http_port}" ];
          }];
          metrics_path = "/metrics";
        }
      ];
    };

    minio = {
      enable = true;
      listenAddress = "127.0.0.1:9000";
      consoleAddress = "127.0.0.1:9001";
      dataDir = [ "/mnt/ssd/databases/minio/data" ];
      configDir = "/mnt/ssd/databases/minio/config";
      region = "eu-west-3";
      browser = true;
      rootCredentialsFile = pkgs.writeText "minio-environment-variable-file" ''
        MINIO_ROOT_USER={{ minio_access_key }}
        MINIO_ROOT_PASSWORD={{ minio_secret_key }}
        MINIO_PROMETHEUS_URL=http://127.0.0.1:${toString config.services.prometheus.port}/prometheus
        MINIO_PROMETHEUS_JOB_ID=minio-job
        MINIO_BROWSER_REDIRECT_URL=http://{{ hostvars['localhost']['internal_domain_name'] }}/minio
        MINIO_PROMETHEUS_AUTH_TYPE=public
      '';
    };

    loki = {
      enable = true;
      dataDir = "/mnt/ssd/monitoring/loki";
      user = "loki";
      group = "loki";
      extraFlags = [
        "-log-config-reverse-order"
      ];
      configuration = {
        auth_enabled = false;
        server = {
          http_listen_address = "127.0.0.1";
          http_listen_port = 3100;
          grpc_listen_address = "0.0.0.0";
          grpc_listen_port = 9095;
        };
        ingester = {
          lifecycler = {
            address = "127.0.0.1";
            ring = {
              kvstore = {
                store = "inmemory";
              };
              replication_factor = 1;
            };
            final_sleep = "0s";
          };
          chunk_idle_period = "5m";
          chunk_retain_period = "30s";
        };
        storage_config = {
          boltdb = {
            directory = "${config.services.loki.dataDir}/index";
          };
          filesystem = {
            directory = "${config.services.loki.dataDir}/chunks";
          };
        };
        schema_config = {
          configs = [{
            from = "2023-01-14";
            store = "boltdb";
            object_store = "filesystem";
            schema = "v11";
            index = {
              prefix = "index_";
              period = "168h";
            };
          }];
        };
        limits_config = {
          enforce_metric_name = false;
          reject_old_samples = true;
          reject_old_samples_max_age = "168h";
        };
      };
    };

    promtail = {
      enable = true;
      extraFlags = [
        "-log-config-reverse-order"
      ];
      configuration = {
        server = {
          disable = false;
          http_listen_address = "127.0.0.1";
          http_listen_port = 9080;
          grpc_listen_address = "127.0.0.1";
          grpc_listen_port = 9096;
        };
        clients = [{
          url = "http://127.0.0.1:${toString config.services.loki.configuration.server.http_listen_port}/loki/api/v1/push";
        }];
        positions = {
          filename = "/mnt/ssd/monitoring/promtail/positions.yaml";
        };
        scrape_configs = [
          {
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
          }
        ];
      };
    };

    grafana = {
      enable = true;
      dataDir = "/mnt/ssd/monitoring/grafana";
      settings = {
        server = {
          protocol = "http";
          http_addr = "127.0.0.1";
          http_port = 3000;
          domain = "{{ hostvars['localhost']['internal_domain_name'] }}";
          root_url = "%(protocol)s://%(domain)s:%(http_port)s/grafana/";
          enable_gzip = true;
        };
        security = {
          admin_user = "{{ hostvars['localhost']['grafana_auth_user'] }}";
          admin_password = "$__file{/var/.grafanaAdminPassword}";
        };
        database = {
          type = "sqlite3";
          path = "${config.services.grafana.dataDir}/data/grafana.db";
        };
        analytics.reporting_enabled = false;
      };
      provision = {
        enable = true;
        datasources.path = pkgs.writeText "datasources.yml" ''
          apiVersion: 1

          datasources:
            - name: Prometheus
              type: prometheus
              access: proxy
              orgId: 1
              uid: {{ prometheus_datasource_uid }}
              url: http://127.0.0.1:${toString config.services.prometheus.port}/prometheus
              isDefault: false
              jsonData:
                manageAlerts: true
                timeInterval: ${toString config.services.prometheus.globalConfig.scrape_interval} # 'Scrape interval' in Grafana UI, defaults to 15s
                httpMethod: POST
                prometheusType: Prometheus
              editable: true

            - name: Loki
              type: loki
              access: proxy
              orgId: 1
              uid: {{ loki_datasource_uid }}
              url: http://127.0.0.1:${toString config.services.loki.configuration.server.http_listen_port}
              isDefault: true
              jsonData:
                manageAlerts: true
                maxLines: 1000
              editable: true
        '';
        dashboards.path = pkgs.writeText "dashboards.yml" ''
          apiVersion: 1

          providers:
            - name: Dashboards
              orgId: 1
              type: file
              disableDeletion: true
              updateIntervalSeconds: 30
              allowUiUpdates: true
              options:
                path: /var/lib/grafana/dashboards
                foldersFromFilesStructure: true
        '';
      };
    };

    nginx = {
      upstreams."grafana" = {
        servers = { "127.0.0.1:${toString config.services.grafana.settings.server.http_port}" = {}; };
      };

      virtualHosts."{{ hostvars['localhost']['internal_domain_name'] }}" = {
        locations."/prometheus" = {
          proxyPass     = "http://127.0.0.1:${toString config.services.prometheus.port}";
          basicAuthFile = /root/.prometheusBasicAuthPasswordFile;
        };

        locations."/minio" = {
          extraConfig = ''
            rewrite ^/minio/(.*) /$1 break;
            proxy_set_header Host $host;

            # Proxy Minio WebSocket connections.
            proxy_http_version 1.1;
            proxy_set_header Upgrade    $http_upgrade;
            proxy_set_header Connection $connection_upgrade;
          '';
          proxyPass = "http://${toString config.services.minio.consoleAddress}";
        };

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
}
