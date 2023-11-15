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
          ports = [ "127.0.0.1:8001:8001" ];
          environment = {
            RIHOST = "0.0.0.0";
            RIPORT = "8001";
            RITRUSTEDORIGINS = "https://${DOMAIN_NAME_INTERNAL}";
            RIPROXYENABLE = "True";
            RIPROXYPATH = "/redisinsight/";
          };
          extraOptions = [
            "--cpus=0.03125"
            "--memory-reservation=122m"
            "--memory=128m"
          ];
          image = (import ./variables.nix).redisinsight_image;
        };
      };
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
            proxy_read_timeout 900;
            proxy_set_header Host $host;
          '';
          proxyPass = "http://127.0.0.1:${config.virtualisation.oci-containers.containers.redisinsight.environment.RIPORT}/";
          basicAuthFile = config.sops.secrets."redisinsight/nginx/file/basic_auth".path;
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
      preStart = "${pkgs.coreutils}/bin/sleep $((RANDOM % 33))";
      serviceConfig = {
        Type = "oneshot";
        EnvironmentFile = [
          config.sops.secrets."1password/application/envs".path
          config.sops.secrets."redisinsight/nginx/envs".path
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
              filename = "/var/lib/private/grafana-agent/positions/redisinsight.yml";
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
                  regex = "(${CONTAINERS_BACKEND}-redisinsight|redisinsight-configure|redisinsight-1password).service";
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
