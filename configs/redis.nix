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
              --enable-module-command local
              --port 6379
              --save 900 1 300 10 60 10000
              --dbfilename dump.rdb
              --maxclients 225
              --maxmemory 122mb
              --appendonly yes
              --appendfilename appendonly.aof
              --appenddirname appendonlydir
            '';
          };
          entrypoint = "/bin/bash";
          extraOptions = [
            "--cpus=0.03125"
            "--memory-reservation=122m"
            "--memory=128m"
          ];
          image = (import ./variables.nix).docker_image_redis;
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
    "1password/application/envs" = {
      mode = "0400";
      owner = config.users.users.root.name;
      group = config.users.users.root.group;
    };
  };

  systemd.services = {
    redis-1password = {
      after = [ "${CONTAINERS_BACKEND}-redis.service" ];
      preStart = "${pkgs.coreutils}/bin/sleep $((RANDOM % ${(import ./variables.nix).one_password_max_delay}))";
      serviceConfig = {
        Type = "oneshot";
        EnvironmentFile = [
          config.sops.secrets."1password/application/envs".path
          config.sops.secrets."redis/application/envs".path
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
            --session $SESSION_TOKEN > /dev/null
          ${pkgs.coreutils}/bin/echo "Item created successfully."
        else
          ${pkgs._1password}/bin/op item edit Redis \
            --vault Server \
            'Default user'.'Connection command'[password]="sudo docker exec -ti redis redis-cli -a '$DEFAULT_USER_PASSWORD'" \
            --session $SESSION_TOKEN > /dev/null
          ${pkgs.coreutils}/bin/echo "Item updated successfully."
        fi
      '';
      wantedBy = [ "${CONTAINERS_BACKEND}-redis.service" ];
    };
  };

  services = {
    grafana-agent = {
      settings = {
        logs = {
          configs = [{
            name = "redis";
            clients = [{
              url = "http://${config.services.loki.configuration.server.http_listen_address}:${toString config.services.loki.configuration.server.http_listen_port}/loki/api/v1/push";
            }];
            positions = {
              filename = "\${STATE_DIRECTORY}/positions/redis.yml";
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
                  regex = "(${CONTAINERS_BACKEND}-redis|redis-1password).service";
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
