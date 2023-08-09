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
    "redis/database_password_file" = {
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
          requirePassFile = config.sops.secrets."redis/database_password_file".path;
          appendOnly = true;
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
          image = "redislabs/redisinsight:1.13.1";
        };
      };
    };
  };

  sops.secrets = {
    "redis/database_password_envs" = {
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
        EnvironmentFile = config.sops.secrets."redis/database_password_envs".path;
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

        ${pkgs.coreutils}/bin/echo "Waiting for RedisInsight availability"
        while ! ${pkgs.wget}/bin/wget -q -O - http://127.0.0.1:${config.virtualisation.oci-containers.containers.redisinsight.environment.RIPORT}/healthcheck/ | grep "OK"; do
          ${pkgs.coreutils}/bin/sleep 1
        done

        ${pkgs.coreutils}/bin/echo "Configuring a connection to the ${REDIS_INSTANCE} database in the Redis"
        ${pkgs.wget}/bin/wget -O - http://127.0.0.1:${config.virtualisation.oci-containers.containers.redisinsight.environment.RIPORT}/api/instance/ \
          --header 'Content-Type: application/json' \
          --post-data "$(post_data)" > /dev/null
      '';
      wantedBy = [
        "redis-${REDIS_INSTANCE}.service"
        "${CONTAINERS_BACKEND}-redisinsight.service"
      ];
    };
  };

  sops.secrets = {
    "redisinsight/nginx_file" = {
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
          basicAuthFile = config.sops.secrets."redisinsight/nginx_file".path;
        };
      };
    };
  };

  sops.secrets = {
    "redis/grafana_agent_envs" = {
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
          config.sops.secrets."redis/database_password_envs".path
          config.sops.secrets."redis/grafana_agent_envs".path
        ];
      };
      script = ''
        ${pkgs.coreutils}/bin/echo "Waiting for Redis availability"
        while ! ${pkgs.netcat}/bin/nc -w 1 -v -z ${config.services.redis.servers.${REDIS_INSTANCE}.bind} ${toString config.services.redis.servers.${REDIS_INSTANCE}.port}; do
          ${pkgs.coreutils}/bin/sleep 1
        done

        ${pkgs.coreutils}/bin/echo "Creating a Grafana Agent account in the Redis"
        ${pkgs.coreutils}/bin/echo "ACL SETUSER $GRAFANA_AGENT_REDIS_USERNAME +client +ping +info +config|get +cluster|info +slowlog +latency +memory +select +get +scan +xinfo +type +pfcount +strlen +llen +scard +zcard +hlen +xlen +eval allkeys on >$GRAFANA_AGENT_REDIS_PASSWORD_CLI" | ${pkgs.redis}/bin/redis-cli -h ${config.services.redis.servers.${REDIS_INSTANCE}.bind} -p ${toString config.services.redis.servers.${REDIS_INSTANCE}.port}
      '';
      wantedBy = [
        "redis-${REDIS_INSTANCE}.service"
        "grafana-agent.service"
      ];
    };
  };

  sops.secrets = {
    "redis/grafana_agent_file/username" = {
      mode = "0400";
      owner = config.users.users.root.name;
      group = config.users.users.root.group;
    };
  };

  sops.secrets = {
    "redis/grafana_agent_file/password" = {
      mode = "0400";
      owner = config.users.users.root.name;
      group = config.users.users.root.group;
    };
  };

  services = {
    grafana-agent = {
      credentials = {
        GRAFANA_AGENT_REDIS_USERNAME = config.sops.secrets."redis/grafana_agent_file/username".path;
        GRAFANA_AGENT_REDIS_PASSWORD = config.sops.secrets."redis/grafana_agent_file/password".path;
      };
      settings = {
        integrations = {
          redis_exporter = {
            enabled = true;
            scrape_interval = "1m";
            redis_addr = "${config.services.redis.servers.${REDIS_INSTANCE}.bind}:${toString config.services.redis.servers.${REDIS_INSTANCE}.port}";
            redis_user = "\${GRAFANA_AGENT_REDIS_USERNAME}";
            redis_password = "\${GRAFANA_AGENT_REDIS_PASSWORD}";
          };
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

  sops.secrets = {
    "redisinsight/nginx_envs" = {
      mode = "0400";
      owner = config.users.users.root.name;
      group = config.users.users.root.group;
    };
  };

  systemd.services = {
    redis-1password = {
      after = [ "${CONTAINERS_BACKEND}-redisinsight.service" ];
      preStart = "${pkgs.coreutils}/bin/sleep $((RANDOM % 21))";
      serviceConfig = let
        entrypoint = pkgs.writeTextFile {
          name = "entrypoint.sh";
          text = ''
            #!/bin/bash

            SESSION_TOKEN=$(echo "$OP_MASTER_PASSWORD" | op account add \
              --address $OP_SUBDOMAIN.1password.com \
              --email $OP_EMAIL_ADDRESS \
              --secret-key $OP_SECRET_KEY \
              --signin --raw)

            op item get Redis \
              --vault 'Local server' \
              --session $SESSION_TOKEN > /dev/null

            if [ $? != 0 ]; then
              op item template get Database --session $SESSION_TOKEN | op item create --vault 'Local server' - \
                --title Redis \
                website[url]=http://${DOMAIN_NAME_INTERNAL}/redisinsight \
                username=$REDISINSIGHT_NGINX_USERNAME \
                password=$REDISINSIGHT_NGINX_PASSWORD \
                'DB connection command - ${REDIS_INSTANCE} DB'[password]="redis-cli -h ${config.services.redis.servers.${REDIS_INSTANCE}.bind} -p ${toString config.services.redis.servers.${REDIS_INSTANCE}.port} -a '$REDISCLI_AUTH'" \
                'DB connection command - Grafana Agent'[password]="redis-cli -u 'redis://$GRAFANA_AGENT_REDIS_USERNAME:$GRAFANA_AGENT_REDIS_PASSWORD_1PASSWORD@${config.services.redis.servers.${REDIS_INSTANCE}.bind}:${toString config.services.redis.servers.${REDIS_INSTANCE}.port}'" \
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
            --name redis-1password \
            --volume ${entrypoint}:/entrypoint.sh \
            --env-file ${config.sops.secrets."1password".path} \
            --env-file ${config.sops.secrets."redisinsight/nginx_envs".path} \
            --env-file ${config.sops.secrets."redis/database_password_envs".path} \
            --env-file ${config.sops.secrets."redis/grafana_agent_envs".path} \
            --entrypoint /entrypoint.sh \
            ${ONE_PASSWORD_IMAGE}'
        '';
      };
      wantedBy = [ "${CONTAINERS_BACKEND}-redisinsight.service" ];
    };
  };
}
