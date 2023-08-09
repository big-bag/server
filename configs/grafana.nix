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
    grafana = {
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
        EnvironmentFile = config.sops.secrets.grafana.path;
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
    "1password" = {
      mode = "0400";
      owner = config.users.users.root.name;
      group = config.users.users.root.group;
    };
  };

  systemd.services = {
    grafana-1password = {
      after = [ "grafana.service" ];
      preStart = "${pkgs.coreutils}/bin/sleep $((RANDOM % 21))";
      serviceConfig = let
        CONTAINERS_BACKEND = config.virtualisation.oci-containers.backend;
        entrypoint = pkgs.writeTextFile {
          name = "entrypoint.sh";
          text = ''
            #!/bin/bash

            SESSION_TOKEN=$(echo "$OP_MASTER_PASSWORD" | op account add \
              --address $OP_SUBDOMAIN.1password.com \
              --email $OP_EMAIL_ADDRESS \
              --secret-key $OP_SECRET_KEY \
              --signin --raw)

            op item get Grafana \
              --vault 'Local server' \
              --session $SESSION_TOKEN > /dev/null

            if [ $? != 0 ]; then
              op item template get Login --session $SESSION_TOKEN | op item create --vault 'Local server' - \
                --title Grafana \
                --url http://${DOMAIN_NAME_INTERNAL}/grafana \
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
        ExecStart = ''${pkgs.bash}/bin/bash -c ' \
          ${pkgs.${CONTAINERS_BACKEND}}/bin/${CONTAINERS_BACKEND} run \
            --rm \
            --name grafana-1password \
            --volume ${entrypoint}:/entrypoint.sh \
            --env-file ${config.sops.secrets."1password".path} \
            --env-file ${config.sops.secrets.grafana.path} \
            --entrypoint /entrypoint.sh \
            ${ONE_PASSWORD_IMAGE}'
        '';
      };
      wantedBy = [ "grafana.service" ];
    };
  };
}
