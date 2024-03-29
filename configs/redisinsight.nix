{ config, pkgs, ... }:

let
  DOMAIN_NAME_INTERNAL = (import ./connection-parameters.nix).domain_name_internal;
  CONTAINERS_BACKEND = config.virtualisation.oci-containers.backend;
  IP_ADDRESS = (import ./connection-parameters.nix).ip_address;
in

{
  virtualisation = {
    oci-containers = {
      containers = {
        redisinsight = {
          autoStart = true;
          ports = [ "127.0.0.1:${config.virtualisation.oci-containers.containers.redisinsight.environment.RIPORT}:${config.virtualisation.oci-containers.containers.redisinsight.environment.RIPORT}" ];
          environment = {
            RIHOST = "0.0.0.0";
            RIPORT = "8001";
            RITRUSTEDORIGINS = "https://${DOMAIN_NAME_INTERNAL}";
            RIPROXYENABLE = "True";
            RIPROXYPATH = "/redisinsight/";
          };
          extraOptions = [
            "--cpus=0.0625"
            "--memory-reservation=243m"
            "--memory=256m"
          ];
          image = (import ./variables.nix).docker_image_redisinsight;
        };
      };
    };
  };

  sops.secrets = {
    "redisinsight/nginx/file/basic_auth" = {
      mode = "0400";
      owner = config.services.nginx.user;
      group = config.services.nginx.group;
    };
  };

  services = {
    nginx = {
      virtualHosts.${DOMAIN_NAME_INTERNAL} = {
        locations."/redisinsight/" = {
          extraConfig = ''
            if ($ssl_client_verify != "SUCCESS") {
              return 496;
            }

            proxy_read_timeout 900;
            proxy_set_header Host $host;
          '';
          basicAuthFile = config.sops.secrets."redisinsight/nginx/file/basic_auth".path;
          proxyPass = "http://127.0.0.1:${config.virtualisation.oci-containers.containers.redisinsight.environment.RIPORT}/";
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
    "redisinsight/nginx/envs" = {
      mode = "0400";
      owner = config.users.users.root.name;
      group = config.users.users.root.group;
    };
  };

  systemd.services = {
    redisinsight-1password = {
      after = [ "${CONTAINERS_BACKEND}-redisinsight.service" ];
      preStart = "${pkgs.coreutils}/bin/sleep $((RANDOM % ${(import ./variables.nix).one_password_max_delay}))";
      serviceConfig = {
        Type = "oneshot";
        EnvironmentFile = [
          config.sops.secrets."1password/application/envs".path
          config.sops.secrets."redisinsight/nginx/envs".path
        ];
      };
      environment = {
        OP_CONFIG_DIR = "/root/.config/op";
      };
      script = ''
        set +e

        SESSION_TOKEN=$(echo "$OP_MASTER_PASSWORD" | ${pkgs._1password}/bin/op account add \
          --address $OP_SUBDOMAIN.1password.com \
          --email $OP_EMAIL_ADDRESS \
          --secret-key $OP_SECRET_KEY \
          --signin --raw)

        ${pkgs._1password}/bin/op item get RedisInsight \
          --vault Server \
          --session $SESSION_TOKEN > /dev/null

        if [ $? != 0 ]
        then
          ${pkgs._1password}/bin/op item template get Login --session $SESSION_TOKEN | ${pkgs._1password}/bin/op item create --vault Server - \
            --title RedisInsight \
            --url https://${DOMAIN_NAME_INTERNAL}/redisinsight \
            username=$NGINX_USERNAME \
            password=$NGINX_PASSWORD \
            --session $SESSION_TOKEN > /dev/null
          ${pkgs.coreutils}/bin/echo "Item created successfully."
        else
          ${pkgs._1password}/bin/op item edit RedisInsight \
            --vault Server \
            --url https://${DOMAIN_NAME_INTERNAL}/redisinsight \
            username=$NGINX_USERNAME \
            password=$NGINX_PASSWORD \
            --session $SESSION_TOKEN > /dev/null
          ${pkgs.coreutils}/bin/echo "Item updated successfully."
        fi
      '';
      wantedBy = [ "${CONTAINERS_BACKEND}-redisinsight.service" ];
    };
  };

  sops.secrets = {
    "redis/application/envs" = {
      mode = "0400";
      owner = config.users.users.root.name;
      group = config.users.users.root.group;
    };
  };

  systemd.services = {
    redisinsight-configure = {
      after = [
        "${CONTAINERS_BACKEND}-redis.service"
        "${CONTAINERS_BACKEND}-redisinsight.service"
      ];
      serviceConfig = {
        Type = "oneshot";
        EnvironmentFile = config.sops.secrets."redis/application/envs".path;
      };
      script = ''
        while ! ${pkgs.wget}/bin/wget -q -O - http://127.0.0.1:${config.virtualisation.oci-containers.containers.redisinsight.environment.RIPORT}/healthcheck/ |
          ${pkgs.gnugrep}/bin/grep OK
        do
          ${pkgs.coreutils}/bin/echo "Waiting for RedisInsight availability."
          ${pkgs.coreutils}/bin/sleep 1
        done

        json_database()
        {
        ${pkgs.coreutils}/bin/cat <<EOF
          {
            "name": "gitlab",
            "connectionType": "STANDALONE",
            "host": "${IP_ADDRESS}",
            "port": 6379,
            "password": "$DEFAULT_USER_PASSWORD"
          }
        EOF
        }

        ${pkgs.wget}/bin/wget -O - http://127.0.0.1:${config.virtualisation.oci-containers.containers.redisinsight.environment.RIPORT}/api/instance/ \
          --header 'Content-Type: application/json' \
          --post-data "$(json_database)" > /dev/null
        ${pkgs.coreutils}/bin/echo "Database added successfully."
      '';
      wantedBy = [
        "${CONTAINERS_BACKEND}-redis.service"
        "${CONTAINERS_BACKEND}-redisinsight.service"
      ];
    };
  };

  services = {
    grafana-agent = {
      settings = {
        logs = {
          configs = [{
            name = "redisinsight";
            clients = [{
              url = "http://${config.services.loki.configuration.server.http_listen_address}:${toString config.services.loki.configuration.server.http_listen_port}/loki/api/v1/push";
            }];
            positions = {
              filename = "\${STATE_DIRECTORY}/positions/redisinsight.yml";
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
                  regex = "(${CONTAINERS_BACKEND}-redisinsight|redisinsight-1password|redisinsight-configure).service";
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

        integrations = {
          blackbox = {
            blackbox_config = {
              modules = {
                redisinsight_http_probe = {
                  prober = "http";
                  timeout = "5s";
                  http = {
                    valid_status_codes = [ 200 ];
                    valid_http_versions = [ "HTTP/1.1" ];
                    method = "GET";
                    follow_redirects = false;
                    fail_if_body_not_matches_regexp = [ "OK" ];
                    enable_http2 = false;
                    preferred_ip_protocol = "ip4";
                  };
                };
              };
            };
            blackbox_targets = [
              {
                name = "redisinsight-http";
                address = "http://127.0.0.1:${config.virtualisation.oci-containers.containers.redisinsight.environment.RIPORT}/healthcheck/";
                module = "redisinsight_http_probe";
              }
            ];
          };
        };
      };
    };
  };
}
