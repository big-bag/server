{ config, pkgs, ... }:

let
  IP_ADDRESS = (import ./connection-parameters.nix).ip_address;
  DOMAIN_NAME_INTERNAL = (import ./connection-parameters.nix).domain_name_internal;
in

{
  systemd.services = {
    prometheus-prepare = {
      before = [
        "var-lib-prometheus2.mount"
        "prometheus-minio.service"
      ];
      serviceConfig = {
        Type = "oneshot";
      };
      script = "${pkgs.coreutils}/bin/mkdir -p /mnt/ssd/monitoring";
      wantedBy = [
        "var-lib-prometheus2.mount"
        "prometheus-minio.service"
      ];
    };
  };

  fileSystems."/var/lib/prometheus2" = {
    device = "/mnt/ssd/monitoring/prometheus2";
    options = [
      "bind"
      "x-systemd.before=prometheus.service"
      "x-systemd.wanted-by=prometheus.service"
    ];
  };

  sops.secrets = {
    "minio/application/envs" = {
      mode = "0400";
      owner = config.users.users.root.name;
      group = config.users.users.root.group;
    };
  };

  systemd.services = {
    prometheus-minio = {
      before = [ "prometheus.service" ];
      serviceConfig = {
        Type = "oneshot";
        EnvironmentFile = config.sops.secrets."minio/application/envs".path;
      };
      environment = {
        ALIAS = "local";
      };
      path = [ pkgs.getent ];
      script = ''
        set +e

        # args: host port
        check_port_is_open() {
          local exit_status_code
          ${pkgs.curl}/bin/curl --silent --connect-timeout 1 --telnet-option "" telnet://"$1:$2" </dev/null
          exit_status_code=$?
          case $exit_status_code in
            49) return 0 ;;
            *) return "$exit_status_code" ;;
          esac
        }

        while true
        do
          check_port_is_open ${IP_ADDRESS} 9000
          if [ $? == 0 ]; then
            ${pkgs.minio-client}/bin/mc alias set $ALIAS http://${IP_ADDRESS}:9000 $MINIO_ROOT_USER $MINIO_ROOT_PASSWORD
            ${pkgs.minio-client}/bin/mc admin prometheus generate $ALIAS | ${pkgs.gnugrep}/bin/grep bearer_token | ${pkgs.gawk}/bin/awk '{ print $2 }' | ${pkgs.coreutils}/bin/tr -d '\n' > /mnt/ssd/monitoring/.minioScrapeBearerToken
            ${pkgs.coreutils}/bin/echo "Prometheus bearer token generated successfully."
            break
          fi
          ${pkgs.coreutils}/bin/echo "Waiting for MinIO availability."
          ${pkgs.coreutils}/bin/sleep 1
        done
      '';
      wantedBy = [ "prometheus.service" ];
    };
  };

  services = {
    prometheus = {
      enable = true;
      listenAddress = "${IP_ADDRESS}";
      port = 9090;
      webExternalUrl = "https://${DOMAIN_NAME_INTERNAL}/prometheus";
      stateDir = "prometheus2";
      retentionTime = "15d";
      checkConfig = "syntax-only";
      enableReload = true;
      globalConfig = {
        scrape_interval = "1m";
        scrape_timeout = "10s";
        evaluation_interval = "1m";
      };
      scrapeConfigs = [
        {
          job_name = "prometheus";
          scrape_interval = "1m";
          scrape_timeout = "10s";
          scheme = "http";
          static_configs = [{
            targets = [ "${config.services.prometheus.listenAddress}:${toString config.services.prometheus.port}" ];
          }];
          metrics_path = "/prometheus/metrics";
        }
        {
          job_name = "minio-job";
          scrape_interval = "1m";
          scrape_timeout = "10s";
          scheme = "http";
          static_configs = [{
            targets = [ "${IP_ADDRESS}:9000" ];
          }];
          metrics_path = "/minio/v2/metrics/cluster";
          bearer_token_file = "/mnt/ssd/monitoring/.minioScrapeBearerToken";
        }
      ];
      remoteWrite = [{
        url = "http://${IP_ADDRESS}:9009/mimir/api/v1/push";
        write_relabel_configs = [{
          source_labels = [ "__name__" ];
          regex = "go_.*|process_.*|minio_.*|action_.*|ci_.*|db_.*|deployments|exporter_.*|gitaly_.*|gitlab_.*|grpc_.*|http_.*|limited_.*|puma_.*|rack_requests_total|registry_.*|ruby_.*|sidekiq_.*|up|web_exporter_.*";
          action = "keep";
        }];
      }];
    };
  };

  systemd.services = {
    prometheus = {
      serviceConfig = {
        CPUQuota = "2%";
        MemoryHigh = "486M";
        MemoryMax = "512M";
      };
    };
  };

  networking = {
    firewall = {
      allowedTCPPorts = [ 9090 ];
    };
  };

  sops.secrets = {
    "prometheus/nginx/file/basic_auth" = {
      mode = "0400";
      owner = config.services.nginx.user;
      group = config.services.nginx.group;
    };
  };

  services = {
    nginx = {
      virtualHosts.${DOMAIN_NAME_INTERNAL} = {
        locations."/prometheus" = {
          proxyPass = "http://${config.services.prometheus.listenAddress}:${toString config.services.prometheus.port}";
          basicAuthFile = config.sops.secrets."prometheus/nginx/file/basic_auth".path;
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

  sops.secrets = {
    "prometheus/nginx/envs" = {
      mode = "0400";
      owner = config.users.users.root.name;
      group = config.users.users.root.group;
    };
  };

  systemd.services = {
    prometheus-1password = {
      after = [ "prometheus.service" ];
      preStart = "${pkgs.coreutils}/bin/sleep $((RANDOM % 36))";
      serviceConfig = {
        Type = "oneshot";
        EnvironmentFile = [
          config.sops.secrets."1password/application/envs".path
          config.sops.secrets."prometheus/nginx/envs".path
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

        ${pkgs._1password}/bin/op item get Prometheus \
          --vault Server \
          --session $SESSION_TOKEN > /dev/null

        if [ $? != 0 ]
        then
          ${pkgs._1password}/bin/op item template get Database --session $SESSION_TOKEN | ${pkgs._1password}/bin/op item create --vault Server - \
            --title Prometheus \
            website[url]=https://${DOMAIN_NAME_INTERNAL}/prometheus \
            username=$NGINX_USERNAME \
            password=$NGINX_PASSWORD \
            --session $SESSION_TOKEN > /dev/null
          ${pkgs.coreutils}/bin/echo "Item created successfully."
        else
          ${pkgs._1password}/bin/op item edit Prometheus \
            --vault Server \
            website[url]=https://${DOMAIN_NAME_INTERNAL}/prometheus \
            username=$NGINX_USERNAME \
            password=$NGINX_PASSWORD \
            --session $SESSION_TOKEN > /dev/null
          ${pkgs.coreutils}/bin/echo "Item updated successfully."
        fi
      '';
      wantedBy = [ "prometheus.service" ];
    };
  };

  services = {
    grafana-agent = {
      settings = {
        logs = {
          configs = [{
            name = "prometheus";
            clients = [{
              url = "http://${config.services.loki.configuration.server.http_listen_address}:${toString config.services.loki.configuration.server.http_listen_port}/loki/api/v1/push";
            }];
            positions = {
              filename = "/var/lib/private/grafana-agent/positions/prometheus.yml";
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
                  regex = "(prometheus-prepare|var-lib-prometheus2|prometheus-minio|prometheus|prometheus-1password).(service|mount)";
                  action = "keep";
                }
                {
                  source_labels = [ "__journal__systemd_unit" ];
                  target_label = "systemd_unit";
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
