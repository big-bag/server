{ config, pkgs, ... }:

{
  services = {
    grafana = {
      enable = true;
      dataDir = "/mnt/ssd/monitoring/grafana";
      settings = {
        server = {
          protocol = "http";
          http_addr = "127.0.0.1";
          http_port = 3000;
          domain = "{{ internal_domain_name }}";
          root_url = "%(protocol)s://%(domain)s:%(http_port)s/grafana/";
          enable_gzip = true;
        };
        security = {
          admin_user = "{{ grafana_username }}";
          admin_password = "{{ grafana_password }}";
        };
      };
      provision = {
        enable = true;
        datasources.path = pkgs.writeText "datasources.yml" ''
          apiVersion: 1

          datasources:
            - name: Mimir
              type: prometheus
              access: proxy
              orgId: 1
              uid: {{ grafana_datasource_uid_mimir }}
              url: http://127.0.0.1:${toString config.services.mimir.configuration.server.http_listen_port}/mimir/prometheus
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
              uid: {{ grafana_datasource_uid_prometheus }}
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
              uid: {{ grafana_datasource_uid_loki }}
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
                path: /mnt/ssd/monitoring/grafana-dashboards
                foldersFromFilesStructure: true
        '';
      };
    };
  };

  services = {
    nginx = {
      upstreams."grafana" = {
        servers = { "127.0.0.1:${toString config.services.grafana.settings.server.http_port}" = {}; };
      };

      virtualHosts."{{ internal_domain_name }}" = {
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

  virtualisation = {
    oci-containers = {
      containers = {
        op-grafana = {
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

              op item get 'Grafana (generated)' \\
                --vault 'Local server' \\
                --session $SESSION_TOKEN

              if [ $? != 0 ]; then
                op item template get Login --session $SESSION_TOKEN | op item create --vault 'Local server' - \\
                  --title 'Grafana (generated)' \\
                  --url http://{{ internal_domain_name }}/grafana \\
                  username='{{ grafana_username }}' \\
                  password='{{ grafana_password }}' \\
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
      grafana = {
        serviceConfig = {
          CPUQuota = "0,78%";
          MemoryHigh = "230M";
          MemoryMax = "256M";
        };
      };

      podman-op-grafana = {
        serviceConfig = {
          RestartPreventExitStatus = 0;
        };
      };
    };
  };
}