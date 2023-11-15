{ config, pkgs, ... }:

let
  IP_ADDRESS = (import ./connection-parameters.nix).ip_address;
  CONTAINERS_BACKEND = config.virtualisation.oci-containers.backend;
in

{
  # https://redis.io/docs/get-started/faq/ -> Background saving fails with a fork() error on Linux?
  boot = {
    kernel = {
      sysctl = {
        "vm.nr_hugepages" = 0;
        "vm.overcommit_memory" = 1;
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

  virtualisation = {
    oci-containers = {
      containers = {
        redis = {
          autoStart = true;
          ports = [ "${IP_ADDRESS}:6379:6379" ];
          volumes = [ "/mnt/ssd/data-stores/redis:/data:rw" ];
          environmentFiles = [ config.sops.secrets."redis/application/envs".path ];
          environment = {
            REDIS_ARGS = ''
              --bind 0.0.0.0
              --port 6379
              --save 900 1 300 10 60 10000
              --dbfilename dump.rdb
              --maxclients 200
              --maxmemory 973mb
              --appendonly yes
              --appendfilename appendonly.aof
              --appenddirname appendonlydir
            '';
          };
          entrypoint = "/bin/bash";
          extraOptions = [
            "--cpus=0.25"
            "--memory-reservation=973m"
            "--memory=1024m"
          ];
          image = (import ./variables.nix).redis_image;
          cmd = [
            "-c" "
              export REDIS_ARGS=\"--requirepass $DEFAULT_USER_PASSWORD $REDIS_ARGS\"
              /entrypoint.sh
            "
          ];
        };
      };
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
      after = [ "${CONTAINERS_BACKEND}-redis.service" ];
      before = [ "grafana-agent.service" ];
      serviceConfig = {
        Type = "oneshot";
        EnvironmentFile = [
          config.sops.secrets."redis/application/envs".path
          config.sops.secrets."redis/grafana_agent/envs".path
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
              COMMAND=$(
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

              case "$COMMAND" in
                "OK" )
                  echo $COMMAND
                  exit 0
                ;;
                "ERR"* )
                  echo $COMMAND
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
    redis-1password = {
      after = [ "${CONTAINERS_BACKEND}-redis.service" ];
      preStart = "${pkgs.coreutils}/bin/sleep $((RANDOM % 33))";
      serviceConfig = {
        Type = "oneshot";
        EnvironmentFile = [
          config.sops.secrets."1password/application/envs".path
          config.sops.secrets."redis/application/envs".path
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
            'Default user'.'Connection command'[password]="sudo docker exec -ti redis redis-cli -a '$DEFAULT_USER_PASSWORD'" \
            'Grafana Agent'.'Connection command'[password]="sudo docker exec -ti redis redis-cli -u 'redis://$REDIS_USERNAME:$REDIS_PASSWORD_1PASSWORD@127.0.0.1:6379'" \
            --session $SESSION_TOKEN > /dev/null
          ${pkgs.coreutils}/bin/echo "Item created successfully."
        else
          ${pkgs._1password}/bin/op item edit Redis \
            --vault Server \
            'Default user'.'Connection command'[password]="sudo docker exec -ti redis redis-cli -a '$DEFAULT_USER_PASSWORD'" \
            'Grafana Agent'.'Connection command'[password]="sudo docker exec -ti redis redis-cli -u 'redis://$REDIS_USERNAME:$REDIS_PASSWORD_1PASSWORD@127.0.0.1:6379'" \
            --session $SESSION_TOKEN > /dev/null
          ${pkgs.coreutils}/bin/echo "Item updated successfully."
        fi
      '';
      wantedBy = [ "${CONTAINERS_BACKEND}-redis.service" ];
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
                  regex = "(${CONTAINERS_BACKEND}-redis|grafana-agent-redis|redis-1password).service";
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
            redis_addr = "${IP_ADDRESS}:6379";
            redis_user = "\${REDIS_USERNAME}";
            redis_password_file = config.sops.secrets."redis/grafana_agent/file/password".path;
          };
        };
      };
    };
  };
}
