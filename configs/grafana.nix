{ config, pkgs, ... }:

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
        datasources.path = pkgs.writeTextFile {
          name = "datasources.yml";
          text = ''
            apiVersion: 1

            datasources:
              - name: Mimir
                type: prometheus
                access: proxy
                orgId: 1
                uid: {{ grafana_datasource_uid_mimir }}
                url: http://${toString config.services.mimir.configuration.server.http_listen_address}:${toString config.services.mimir.configuration.server.http_listen_port}/mimir/prometheus
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
                url: http://${toString config.services.prometheus.listenAddress}:${toString config.services.prometheus.port}/prometheus
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
                url: http://${toString config.services.loki.configuration.server.http_listen_address}:${toString config.services.loki.configuration.server.http_listen_port}
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
          GRAFANA_ADDRESS = "${toString config.services.grafana.settings.server.http_addr}:${toString config.services.grafana.settings.server.http_port}";
        in { "${GRAFANA_ADDRESS}" = {}; };
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

  systemd.services = {
    grafana-1password = {
      after = [
        "grafana.service"
        "nginx.service"
      ];
      serviceConfig = let
        CONTAINERS_BACKEND = "${config.virtualisation.oci-containers.backend}";
        ENTRYPOINT = pkgs.writeTextFile {
          name = "entrypoint.sh";
          text = ''
            #!/bin/bash

            SESSION_TOKEN=$(echo "$OP_MASTER_PASSWORD" | op account add \
              --address $OP_SUBDOMAIN.1password.com \
              --email $OP_EMAIL_ADDRESS \
              --secret-key $OP_SECRET_KEY \
              --signin --raw)

            op item get 'Grafana (generated)' \
              --vault 'Local server' \
              --session $SESSION_TOKEN > /dev/null

            if [ $? != 0 ]; then
              op item template get Login --session $SESSION_TOKEN | op item create --vault 'Local server' - \
                --title 'Grafana (generated)' \
                --url http://$INTERNAL_DOMAIN_NAME/grafana \
                username=$GRAFANA_USERNAME \
                password=$GRAFANA_PASSWORD \
                --session $SESSION_TOKEN > /dev/null
            fi
          '';
          executable = true;
        };
        ONE_PASSWORD_IMAGE = (import /etc/nixos/variables.nix).one_password_image;
      in {
        Type = "oneshot";
        EnvironmentFile = pkgs.writeTextFile {
          name = ".env";
          text = ''
            OP_DEVICE = {{ hostvars['localhost']['vault_1password_device_id'] }}
            OP_MASTER_PASSWORD = {{ hostvars['localhost']['vault_1password_master_password'] }}
            OP_SUBDOMAIN = {{ hostvars['localhost']['vault_1password_subdomain'] }}
            OP_EMAIL_ADDRESS = {{ hostvars['localhost']['vault_1password_email_address'] }}
            OP_SECRET_KEY = {{ hostvars['localhost']['vault_1password_secret_key'] }}
            INTERNAL_DOMAIN_NAME = {{ internal_domain_name }}
            GRAFANA_USERNAME = {{ grafana_username }}
            GRAFANA_PASSWORD = {{ grafana_password }}
          '';
        };
        ExecStart = ''${pkgs.bash}/bin/bash -c ' \
          ${pkgs.${CONTAINERS_BACKEND}}/bin/${CONTAINERS_BACKEND} run \
            --rm \
            --name grafana-1password \
            --volume ${ENTRYPOINT}:/entrypoint.sh \
            --env OP_DEVICE=$OP_DEVICE \
            --env OP_MASTER_PASSWORD="$OP_MASTER_PASSWORD" \
            --env OP_SUBDOMAIN=$OP_SUBDOMAIN \
            --env OP_EMAIL_ADDRESS=$OP_EMAIL_ADDRESS \
            --env OP_SECRET_KEY=$OP_SECRET_KEY \
            --env INTERNAL_DOMAIN_NAME=$INTERNAL_DOMAIN_NAME \
            --env GRAFANA_USERNAME=$GRAFANA_USERNAME \
            --env GRAFANA_PASSWORD=$GRAFANA_PASSWORD \
            --entrypoint /entrypoint.sh \
            --cpus 0.01563 \
            --memory-reservation 61m \
            --memory 64m \
            ${ONE_PASSWORD_IMAGE}'
        '';
      };
      wantedBy = [ "grafana.service" ];
    };
  };
}
