{ config, pkgs, ... }:

let
  REDIS_INSTANCE = (import ./variables.nix).redis_instance;
in

{
  systemd.services = {
    redis-prepare = {
      before = [ "var-lib-redis\\x2d${REDIS_INSTANCE}.mount" ];
      serviceConfig = {
        Type = "oneshot";
      };
      script = "${pkgs.coreutils}/bin/mkdir -p /mnt/ssd/data-stores";
      wantedBy = [ "var-lib-redis\\x2d${REDIS_INSTANCE}.mount" ];
    };
  };

  fileSystems."/var/lib/redis-${REDIS_INSTANCE}" = {
    device = "/mnt/ssd/data-stores/redis-${REDIS_INSTANCE}";
    options = [
      "bind"
      "x-systemd.before=redis-${REDIS_INSTANCE}.service"
      "x-systemd.wanted-by=redis-${REDIS_INSTANCE}.service"
    ];
  };

  sops.secrets = {
    "redis/database/file/password" = {
      mode = "0400";
      owner = config.services.redis.servers.${REDIS_INSTANCE}.user;
      group = config.services.redis.servers.${REDIS_INSTANCE}.user;
    };
  };

  services = {
    redis = {
      vmOverCommit = true;
      servers = {
        ${REDIS_INSTANCE} = let
          IP_ADDRESS = (import ./connection-parameters.nix).ip_address;
        in {
          enable = true;
          user = "redis-${REDIS_INSTANCE}";
          bind = "${IP_ADDRESS}";
          port = 6379;
          requirePassFile = config.sops.secrets."redis/database/file/password".path;
          appendOnly = true;
          maxclients = 200;
          settings = {
            maxmemory = "973mb";
          };
        };
      };
    };
  };

  systemd.services."redis-${REDIS_INSTANCE}" = {
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
    serviceConfig = {
      CPUQuota = "3%";
      MemoryHigh = "973M";
      MemoryMax = "1024M";
    };
  };

  networking = {
    firewall = {
      allowedTCPPorts = [ 6379 ];
    };
  };

  sops.secrets = {
    "redis/grafana_agent/envs" = {
      mode = "0400";
      owner = config.users.users.root.name;
      group = config.users.users.root.group;
    };
  };

  systemd.services = {
    grafana-agent-redis = {
      after = [ "redis-${REDIS_INSTANCE}.service" ];
      before = [ "grafana-agent.service" ];
      serviceConfig = {
        Type = "oneshot";
        EnvironmentFile = [
          config.sops.secrets."redis/database/envs".path
          config.sops.secrets."redis/grafana_agent/envs".path
        ];
      };
      script = ''
        while ! ${pkgs.netcat}/bin/nc -w 1 -v -z ${config.services.redis.servers.${REDIS_INSTANCE}.bind} ${toString config.services.redis.servers.${REDIS_INSTANCE}.port}; do
          ${pkgs.coreutils}/bin/echo "Waiting for Redis availability."
          ${pkgs.coreutils}/bin/sleep 1
        done

        COMMAND=$(
          ${pkgs.coreutils}/bin/echo "ACL SETUSER $REDIS_USERNAME \
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
            >$REDIS_PASSWORD_CLI" |
          ${pkgs.redis}/bin/redis-cli \
            -h ${config.services.redis.servers.${REDIS_INSTANCE}.bind} \
            -p ${toString config.services.redis.servers.${REDIS_INSTANCE}.port}
        )

        case "$COMMAND" in
          "OK" )
            ${pkgs.coreutils}/bin/echo $COMMAND
            exit 0
          ;;
          "ERR"* )
            ${pkgs.coreutils}/bin/echo $COMMAND
            exit 1
          ;;
        esac
      '';
      wantedBy = [
        "redis-${REDIS_INSTANCE}.service"
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
    redis-1password = {
      after = [ "redis-${REDIS_INSTANCE}.service" ];
      preStart = "${pkgs.coreutils}/bin/sleep $((RANDOM % 33))";
      serviceConfig = {
        Type = "oneshot";
        EnvironmentFile = [
          config.sops.secrets."1password/application/envs".path
          config.sops.secrets."redis/database/envs".path
          config.sops.secrets."redis/grafana_agent/envs".path
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

        ${pkgs._1password}/bin/op item get Redis \
          --vault Server \
          --session $SESSION_TOKEN > /dev/null

        if [ $? != 0 ]
        then
          ${pkgs._1password}/bin/op item template get Database --session $SESSION_TOKEN | ${pkgs._1password}/bin/op item create --vault Server - \
            --title Redis \
            '${REDIS_INSTANCE} instance'.'Connection command'[password]="redis-cli -h ${config.services.redis.servers.${REDIS_INSTANCE}.bind} -p ${toString config.services.redis.servers.${REDIS_INSTANCE}.port} -a '$REDISCLI_AUTH'" \
            'Grafana Agent'.'Connection command'[password]="redis-cli -u 'redis://$REDIS_USERNAME:$REDIS_PASSWORD_1PASSWORD@${config.services.redis.servers.${REDIS_INSTANCE}.bind}:${toString config.services.redis.servers.${REDIS_INSTANCE}.port}'" \
            --session $SESSION_TOKEN > /dev/null
          ${pkgs.coreutils}/bin/echo "Item created successfully."
        else
          ${pkgs._1password}/bin/op item edit Redis \
            --vault Server \
            '${REDIS_INSTANCE} instance'.'Connection command'[password]="redis-cli -h ${config.services.redis.servers.${REDIS_INSTANCE}.bind} -p ${toString config.services.redis.servers.${REDIS_INSTANCE}.port} -a '$REDISCLI_AUTH'" \
            'Grafana Agent'.'Connection command'[password]="redis-cli -u 'redis://$REDIS_USERNAME:$REDIS_PASSWORD_1PASSWORD@${config.services.redis.servers.${REDIS_INSTANCE}.bind}:${toString config.services.redis.servers.${REDIS_INSTANCE}.port}'" \
            --session $SESSION_TOKEN > /dev/null
          ${pkgs.coreutils}/bin/echo "Item updated successfully."
        fi
      '';
      wantedBy = [ "redis-${REDIS_INSTANCE}.service" ];
    };
  };

  sops.secrets = {
    "redis/grafana_agent/file/username" = {
      mode = "0400";
      owner = config.users.users.root.name;
      group = config.users.users.root.group;
    };
  };

  sops.secrets = {
    "redis/grafana_agent/file/password" = {
      mode = "0404";
      owner = config.users.users.root.name;
      group = config.users.users.root.group;
    };
  };

  services = {
    grafana-agent = {
      credentials = {
        REDIS_USERNAME = config.sops.secrets."redis/grafana_agent/file/username".path;
      };

      settings = {
        logs = {
          configs = [{
            name = "redis";
            clients = [{
              url = "http://${config.services.loki.configuration.server.http_listen_address}:${toString config.services.loki.configuration.server.http_listen_port}/loki/api/v1/push";
            }];
            positions = {
              filename = "/var/lib/private/grafana-agent/positions/redis.yml";
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
                  regex = "(redis-prepare|var-lib-redis\\x2d${REDIS_INSTANCE}|redis-${REDIS_INSTANCE}|grafana-agent-redis|redis-1password).(service|mount)";
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

        integrations = {
          redis_exporter = {
            enabled = true;
            scrape_interval = "1m";
            scrape_timeout = "10s";
            redis_addr = "${config.services.redis.servers.${REDIS_INSTANCE}.bind}:${toString config.services.redis.servers.${REDIS_INSTANCE}.port}";
            redis_user = "\${REDIS_USERNAME}";
            redis_password_file = config.sops.secrets."redis/grafana_agent/file/password".path;
          };
        };
      };
    };
  };
}
