{ config, pkgs, ... }:

let
  CONTAINERS_BACKEND = config.virtualisation.oci-containers.backend;
in

{
  sops.secrets = {
    "redis_exporter/redis/envs" = {
      mode = "0400";
      owner = config.users.users.root.name;
      group = config.users.users.root.group;
    };
  };

  systemd.services = {
    redis-exporter-redis = {
      after = [ "${CONTAINERS_BACKEND}-redis.service" ];
      before = [ "grafana-agent.service" ];
      serviceConfig = {
        Type = "oneshot";
        EnvironmentFile = [
          config.sops.secrets."redis/application/envs".path
          config.sops.secrets."redis_exporter/redis/envs".path
        ];
      };
      script = ''
        while ! ${pkgs.${CONTAINERS_BACKEND}}/bin/${CONTAINERS_BACKEND} exec \
          --env REDISCLI_AUTH=$DEFAULT_USER_PASSWORD \
          redis \
            redis-cli PING |
          ${pkgs.gnugrep}/bin/grep PONG
        do
          ${pkgs.coreutils}/bin/echo "Waiting for Redis availability."
          ${pkgs.coreutils}/bin/sleep 1
        done

        ${pkgs.${CONTAINERS_BACKEND}}/bin/${CONTAINERS_BACKEND} exec \
          --env USERNAME=$REDIS_USERNAME \
          --env PASSWORD=$REDIS_PASSWORD_CLI \
          --env REDISCLI_AUTH=$DEFAULT_USER_PASSWORD \
          redis \
            /bin/bash -c '
              CLI_COMMAND=$(
                echo "ACL SETUSER $USERNAME \
                  reset \
                  +client \
                  +ping \
                  +info \
                  +config|get \
                  +cluster|info \
                  +slowlog \
                  +latency \
                  +memory \
                  +select \
                  +get \
                  +scan \
                  +xinfo \
                  +type \
                  +pfcount \
                  +strlen \
                  +llen \
                  +scard \
                  +zcard \
                  +hlen \
                  +xlen \
                  +eval \
                  allkeys \
                  on \
                  >$PASSWORD" |
                redis-cli
              )

              case "$CLI_COMMAND" in
                "OK" )
                  echo $CLI_COMMAND
                  exit 0
                ;;
                "ERR"* )
                  echo $CLI_COMMAND
                  exit 1
                ;;
              esac
            '
      '';
      wantedBy = [
        "${CONTAINERS_BACKEND}-redis.service"
        "grafana-agent.service"
      ];
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
    redis-exporter-1password = {
      after = [
        "redis-1password.service"
        "redis-exporter-redis.service"
      ];
      preStart = "${pkgs.coreutils}/bin/sleep $((RANDOM % ${(import ./variables.nix).one_password_max_delay}))";
      serviceConfig = {
        Type = "oneshot";
        EnvironmentFile = [
          config.sops.secrets."1password/application/envs".path
          config.sops.secrets."redis_exporter/redis/envs".path
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

        ${pkgs._1password}/bin/op item edit Redis \
          --vault Server \
          'Grafana Agent'.'Connection command'[password]="sudo docker exec -ti redis redis-cli -u 'redis://$REDIS_USERNAME:$REDIS_PASSWORD_1PASSWORD@127.0.0.1:6379'" \
          --session $SESSION_TOKEN > /dev/null
        ${pkgs.coreutils}/bin/echo "Item updated successfully."
      '';
      wantedBy = [
        "redis-1password.service"
        "redis-exporter-redis.service"
      ];
    };
  };

  sops.secrets = {
    "redis_exporter/redis/file/username" = {
      mode = "0400";
      owner = config.users.users.root.name;
      group = config.users.users.root.group;
    };
  };

  sops.secrets = {
    "redis_exporter/redis/file/password" = {
      mode = "0404";
      owner = config.users.users.root.name;
      group = config.users.users.root.group;
    };
  };

  services = {
    grafana-agent = {
      credentials = {
        REDIS_USERNAME = config.sops.secrets."redis_exporter/redis/file/username".path;
      };

      settings = {
        logs = {
          configs = [{
            name = "redis-exporter";
            clients = [{
              url = "http://${config.services.loki.configuration.server.http_listen_address}:${toString config.services.loki.configuration.server.http_listen_port}/loki/api/v1/push";
            }];
            positions = {
              filename = "\${STATE_DIRECTORY}/positions/redis-exporter.yml";
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
                  regex = "(redis-exporter-redis|redis-exporter-1password).service";
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

        integrations = let
          IP_ADDRESS = (import ./connection-parameters.nix).ip_address;
        in {
          redis_exporter = {
            enabled = true;
            scrape_integration = true;
            scrape_interval = "1m";
            scrape_timeout = "10s";
            redis_addr = "${IP_ADDRESS}:6379";
            redis_user = "\${REDIS_USERNAME}";
            redis_password_file = config.sops.secrets."redis_exporter/redis/file/password".path;
          };

          blackbox = {
            blackbox_config = {
              modules = {
                redis_tcp_probe = {
                  prober = "tcp";
                  timeout = "5s";
                  tcp = {
                    preferred_ip_protocol = "ip4";
                    source_ip_address = "${IP_ADDRESS}";
                  };
                };
              };
            };
            blackbox_targets = [
              {
                name = "redis-tcp";
                address = "${IP_ADDRESS}:6379";
                module = "redis_tcp_probe";
              }
            ];
          };
        };
      };
    };
  };
}
