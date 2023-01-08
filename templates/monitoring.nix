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
          job_name = "grafana";
          scheme = "http";
          static_configs = [{
            targets = [ "127.0.0.1:${toString config.services.grafana.settings.server.http_port}" ];
          }];
          metrics_path = "/metrics";
        }
      ];
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
              isDefault: true
              jsonData:
                manageAlerts: true
                timeInterval: ${toString config.services.prometheus.globalConfig.scrape_interval} # 'Scrape interval' in Grafana UI, defaults to 15s
                httpMethod: POST
                prometheusType: Prometheus
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
