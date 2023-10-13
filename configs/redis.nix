{ config, pkgs, ... }:

let
  REDIS_INSTANCE = (import /etc/nixos/variables.nix).redis_instance;
  DOMAIN_NAME_INTERNAL = (import ./connection-parameters.nix).domain_name_internal;
  CONTAINERS_BACKEND = config.virtualisation.oci-containers.backend;
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
    "redis/database_password/file" = {
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
          requirePassFile = config.sops.secrets."redis/database_password/file".path;
          appendOnly = true;
          maxclients = 150;
          settings = {
            maxmemory = "973mb";
          };
        };
      };
    };
  };

  systemd.services."redis-${REDIS_INSTANCE}" = {
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
          image = (import /etc/nixos/variables.nix).redisinsight_image;
        };
      };
    };
  };

  sops.secrets = {
    "redis/database_password/envs" = {
      mode = "0400";
      owner = config.users.users.root.name;
      group = config.users.users.root.group;
    };
  };

  systemd.services = {
    redisinsight-configure = {
      after = [
        "redis-${REDIS_INSTANCE}.service"
        "${CONTAINERS_BACKEND}-redisinsight.service"
      ];
      serviceConfig = {
        Type = "oneshot";
        EnvironmentFile = config.sops.secrets."redis/database_password/envs".path;
      };
      script = ''
        post_data()
        {
        ${pkgs.coreutils}/bin/cat <<EOF
          {
            "name": "${REDIS_INSTANCE}",
            "connectionType": "STANDALONE",
            "host": "${config.services.redis.servers.${REDIS_INSTANCE}.bind}",
            "port": ${toString config.services.redis.servers.${REDIS_INSTANCE}.port},
            "password": "$REDISCLI_AUTH"
          }
        EOF
        }

        while ! ${pkgs.wget}/bin/wget -q -O - http://127.0.0.1:${config.virtualisation.oci-containers.containers.redisinsight.environment.RIPORT}/healthcheck/ | grep "OK"; do
          ${pkgs.coreutils}/bin/echo "Waiting for RedisInsight availability."
          ${pkgs.coreutils}/bin/sleep 1
        done

        ${pkgs.wget}/bin/wget -O - http://127.0.0.1:${config.virtualisation.oci-containers.containers.redisinsight.environment.RIPORT}/api/instance/ \
          --header 'Content-Type: application/json' \
          --post-data "$(post_data)" > /dev/null
        ${pkgs.coreutils}/bin/echo "${REDIS_INSTANCE} database added successfully."
      '';
      wantedBy = [
        "redis-${REDIS_INSTANCE}.service"
        "${CONTAINERS_BACKEND}-redisinsight.service"
      ];
    };
  };

  sops.secrets = {
    "redisinsight/nginx/file" = {
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
            proxy_set_header   Host $host;
          '';
          proxyPass = "http://127.0.0.1:${config.virtualisation.oci-containers.containers.redisinsight.environment.RIPORT}/";
          basicAuthFile = config.sops.secrets."redisinsight/nginx/file".path;
        };
      };
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
    redis-grafana-agent = {
      after = [ "redis-${REDIS_INSTANCE}.service" ];
      before = [ "grafana-agent.service" ];
      serviceConfig = {
        Type = "oneshot";
        EnvironmentFile = [
          config.sops.secrets."redis/database_password/envs".path
          config.sops.secrets."redis/grafana_agent/envs".path
        ];
      };
      script = ''
        while ! ${pkgs.netcat}/bin/nc -w 1 -v -z ${config.services.redis.servers.${REDIS_INSTANCE}.bind} ${toString config.services.redis.servers.${REDIS_INSTANCE}.port}; do
          ${pkgs.coreutils}/bin/echo "Waiting for Redis availability."
          ${pkgs.coreutils}/bin/sleep 1
        done

        ${pkgs.coreutils}/bin/echo "ACL SETUSER $GRAFANA_AGENT_REDIS_USERNAME +client +ping +info +config|get +cluster|info +slowlog +latency +memory +select +get +scan +xinfo +type +pfcount +strlen +llen +scard +zcard +hlen +xlen +eval allkeys on >$GRAFANA_AGENT_REDIS_PASSWORD_CLI" | ${pkgs.redis}/bin/redis-cli -h ${config.services.redis.servers.${REDIS_INSTANCE}.bind} -p ${toString config.services.redis.servers.${REDIS_INSTANCE}.port}
        ${pkgs.coreutils}/bin/echo "Grafana Agent account created successfully."
      '';
      wantedBy = [
        "redis-${REDIS_INSTANCE}.service"
        "grafana-agent.service"
      ];
    };
  };

  sops.secrets = {
    "1password/envs" = {
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
    redis-1password = {
      after = [ "${CONTAINERS_BACKEND}-redisinsight.service" ];
      preStart = "${pkgs.coreutils}/bin/sleep $((RANDOM % 24))";
      serviceConfig = {
        Type = "oneshot";
        EnvironmentFile = [
          config.sops.secrets."1password/envs".path
          config.sops.secrets."redisinsight/nginx/envs".path
          config.sops.secrets."redis/database_password/envs".path
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
            website[url]=http://${DOMAIN_NAME_INTERNAL}/redisinsight \
            username=$REDISINSIGHT_NGINX_USERNAME \
            password=$REDISINSIGHT_NGINX_PASSWORD \
            'DB connection command'.'${REDIS_INSTANCE} DB'[password]="redis-cli -h ${config.services.redis.servers.${REDIS_INSTANCE}.bind} -p ${toString config.services.redis.servers.${REDIS_INSTANCE}.port} -a '$REDISCLI_AUTH'" \
            'DB connection command'.'Grafana Agent'[password]="redis-cli -u 'redis://$GRAFANA_AGENT_REDIS_USERNAME:$GRAFANA_AGENT_REDIS_PASSWORD_1PASSWORD@${config.services.redis.servers.${REDIS_INSTANCE}.bind}:${toString config.services.redis.servers.${REDIS_INSTANCE}.port}'" \
            --session $SESSION_TOKEN > /dev/null

          ${pkgs.coreutils}/bin/echo "Item created successfully."
        else
          ${pkgs._1password}/bin/op item edit Redis \
            --vault Server \
            website[url]=http://${DOMAIN_NAME_INTERNAL}/redisinsight \
            username=$REDISINSIGHT_NGINX_USERNAME \
            password=$REDISINSIGHT_NGINX_PASSWORD \
            'DB connection command'.'${REDIS_INSTANCE} DB'[password]="redis-cli -h ${config.services.redis.servers.${REDIS_INSTANCE}.bind} -p ${toString config.services.redis.servers.${REDIS_INSTANCE}.port} -a '$REDISCLI_AUTH'" \
            'DB connection command'.'Grafana Agent'[password]="redis-cli -u 'redis://$GRAFANA_AGENT_REDIS_USERNAME:$GRAFANA_AGENT_REDIS_PASSWORD_1PASSWORD@${config.services.redis.servers.${REDIS_INSTANCE}.bind}:${toString config.services.redis.servers.${REDIS_INSTANCE}.port}'" \
            --session $SESSION_TOKEN > /dev/null

          ${pkgs.coreutils}/bin/echo "Item edited successfully."
        fi
      '';
      wantedBy = [ "${CONTAINERS_BACKEND}-redisinsight.service" ];
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
        GRAFANA_AGENT_REDIS_USERNAME = config.sops.secrets."redis/grafana_agent/file/username".path;
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
                  regex = "(redis-prepare|var-lib-redis\\x2d${REDIS_INSTANCE}|redis-${REDIS_INSTANCE}|${CONTAINERS_BACKEND}-redisinsight|redisinsight-configure|redis-grafana-agent|redis-1password).(service|mount)";
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
            redis_user = "\${GRAFANA_AGENT_REDIS_USERNAME}";
            redis_password_file = config.sops.secrets."redis/grafana_agent/file/password".path;
          };
        };
      };
    };
  };
}
