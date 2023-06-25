{ config, pkgs, ... }:

let
  REDIS_INSTANCE = (import /etc/nixos/variables.nix).redis_instance;
  CONTAINERS_BACKEND = "${config.virtualisation.oci-containers.backend}";
  NETWORK = "redisinsight";
in

{
  systemd.services = {
    "redis-${REDIS_INSTANCE}-prepare" = {
      before = [
        "var-lib-redis\\x2d${REDIS_INSTANCE}.mount"
        "${CONTAINERS_BACKEND}-redisinsight.service"
        "redis-configure.service"
      ];
      serviceConfig = {
        Type = "oneshot";
      };
      script = ''
        ${pkgs.coreutils}/bin/mkdir -p /mnt/ssd/data-stores

        if [ -z $(${pkgs.${CONTAINERS_BACKEND}}/bin/${CONTAINERS_BACKEND} network ls --filter name=^${NETWORK}$ --format {% raw %}{{.Name}}{% endraw %}) ]; then
          ${pkgs.${CONTAINERS_BACKEND}}/bin/${CONTAINERS_BACKEND} network create ${NETWORK}
        fi
      '';
      wantedBy = [
        "var-lib-redis\\x2d${REDIS_INSTANCE}.mount"
        "${CONTAINERS_BACKEND}-redisinsight.service"
        "redis-configure.service"
      ];
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

  services = {
    redis = {
      vmOverCommit = true;
      servers = {
        ${REDIS_INSTANCE} = {
          enable = true;
          bind = "{{ ansible_default_ipv4.address }}";
          port = 6379;
          requirePass = "{{ redis_database_password }}";
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
            RITRUSTEDORIGINS = "https://{{ internal_domain_name }}";
            RIPROXYENABLE = "True";
            RIPROXYPATH = "/redisinsight/";
          };
          extraOptions = [
            "--network=${NETWORK}"
            "--cpus=0.03125"
            "--memory-reservation=122m"
            "--memory=128m"
          ];
          image = "redislabs/redisinsight:1.13.1";
        };
      };
    };
  };

  services = {
    nginx = {
      virtualHosts."{{ internal_domain_name }}" = {
        locations."/redisinsight/" = {
          extraConfig = ''
            proxy_read_timeout 900;
            proxy_set_header   Host $host;
          '';
          proxyPass = "http://127.0.0.1:${toString config.virtualisation.oci-containers.containers.redisinsight.environment.RIPORT}/";
          basicAuth = { {{ redis_redisinsight_username }} = "{{ redis_redisinsight_password }}"; };
        };
      };
    };
  };

  systemd.services = {
    redis-configure = {
      after = [
        "redis-${REDIS_INSTANCE}.service"
        "${CONTAINERS_BACKEND}-redisinsight.service"
      ];
      serviceConfig = let
        ENTRYPOINT = pkgs.writeTextFile {
          name = "entrypoint.sh";
          text = ''
            #!/bin/sh

            post_data()
            {
            cat <<EOF
              {
                "name": "${REDIS_INSTANCE}",
                "connectionType": "STANDALONE",
                "host": "${toString config.services.redis.servers.${REDIS_INSTANCE}.bind}",
                "port": ${toString config.services.redis.servers.${REDIS_INSTANCE}.port},
                "password": "$REDISCLI_AUTH"
              }
            EOF
            }

            for i in `seq 1 300`; do
              wget -q -O - http://redisinsight:${toString config.virtualisation.oci-containers.containers.redisinsight.environment.RIPORT}/healthcheck/ | grep "OK"
              if [ $? == 0 ]; then
                wget -O - http://redisinsight:${toString config.virtualisation.oci-containers.containers.redisinsight.environment.RIPORT}/api/instance/ \
                  --header 'Content-Type: application/json' \
                  --post-data "$(post_data)" > /dev/null
                echo "ACL SETUSER $REDIS_MONITORING_DATABASE_USERNAME +client +ping +info +config|get +cluster|info +slowlog +latency +memory +select +get +scan +xinfo +type +pfcount +strlen +llen +scard +zcard +hlen +xlen +eval allkeys on >$REDIS_MONITORING_DATABASE_PASSWORD" | redis-cli -h ${toString config.services.redis.servers.${REDIS_INSTANCE}.bind} -p ${toString config.services.redis.servers.${REDIS_INSTANCE}.port}
                exit 0
              fi
              sleep 1
            done
          '';
          executable = true;
        };
      in {
        Type = "oneshot";
        EnvironmentFile = pkgs.writeTextFile {
          name = ".env";
          text = ''
            REDIS_DATABASE_PASSWORD = {{ redis_database_password }}
            REDIS_MONITORING_DATABASE_USERNAME = {{ redis_monitoring_database_username }}
            REDIS_MONITORING_DATABASE_PASSWORD = {{ redis_monitoring_database_password }}
          '';
        };
        ExecStart = ''${pkgs.bash}/bin/bash -c ' \
          ${pkgs.${CONTAINERS_BACKEND}}/bin/${CONTAINERS_BACKEND} run \
            --rm \
            --name redis-configure \
            --network=${NETWORK} \
            --volume ${ENTRYPOINT}:/entrypoint.sh \
            --env REDISCLI_AUTH=$REDIS_DATABASE_PASSWORD \
            --env REDIS_MONITORING_DATABASE_USERNAME=$REDIS_MONITORING_DATABASE_USERNAME \
            --env REDIS_MONITORING_DATABASE_PASSWORD=$REDIS_MONITORING_DATABASE_PASSWORD \
            --entrypoint /entrypoint.sh \
            --cpus 0.01563 \
            --memory-reservation 61m \
            --memory 64m \
            redis:7.0.10-alpine3.17'
        '';
      };
      wantedBy = [
        "redis-${REDIS_INSTANCE}.service"
        "${CONTAINERS_BACKEND}-redisinsight.service"
      ];
    };
  };

  systemd.services = {
    redis-1password = {
      after = [
        "${CONTAINERS_BACKEND}-redisinsight.service"
        "nginx.service"
      ];
      serviceConfig = let
        ENTRYPOINT = pkgs.writeTextFile {
          name = "entrypoint.sh";
          text = ''
            #!/bin/bash

            SESSION_TOKEN=$(echo "$OP_MASTER_PASSWORD" | op account add \
              --address $OP_SUBDOMAIN.1password.com \
              --email $OP_EMAIL_ADDRESS \
              --secret-key $OP_SECRET_KEY \
              --signin --raw)

            op item get 'Redis (generated)' \
              --vault 'Local server' \
              --session $SESSION_TOKEN > /dev/null

            if [ $? != 0 ]; then
              op item template get Database --session $SESSION_TOKEN | op item create --vault 'Local server' - \
                --title 'Redis (generated)' \
                website[url]=http://$INTERNAL_DOMAIN_NAME/redisinsight \
                username=$REDIS_REDISINSIGHT_USERNAME \
                password=$REDIS_REDISINSIGHT_PASSWORD \
                'DB ${REDIS_INSTANCE} password'[password]=$REDIS_DATABASE_PASSWORD \
                --session $SESSION_TOKEN > /dev/null
            fi
          '';
          executable = true;
        };
        ONE_PASSWORD_IMAGE = (import /etc/nixos/variables.nix).one_password_image;
      in {
        Type = "oneshot";
        EnvironmentFile = pkgs.writeTextFile {
          name = ".env";
          text = ''
            OP_DEVICE = {{ hostvars['localhost']['vault_1password_device_id'] }}
            OP_MASTER_PASSWORD = {{ hostvars['localhost']['vault_1password_master_password'] }}
            OP_SUBDOMAIN = {{ hostvars['localhost']['vault_1password_subdomain'] }}
            OP_EMAIL_ADDRESS = {{ hostvars['localhost']['vault_1password_email_address'] }}
            OP_SECRET_KEY = {{ hostvars['localhost']['vault_1password_secret_key'] }}
            INTERNAL_DOMAIN_NAME = {{ internal_domain_name }}
            REDIS_REDISINSIGHT_USERNAME = {{ redis_redisinsight_username }}
            REDIS_REDISINSIGHT_PASSWORD = {{ redis_redisinsight_password }}
            REDIS_DATABASE_PASSWORD = {{ redis_database_password }}
          '';
        };
        ExecStart = ''${pkgs.bash}/bin/bash -c ' \
          ${pkgs.${CONTAINERS_BACKEND}}/bin/${CONTAINERS_BACKEND} run \
            --rm \
            --name redis-1password \
            --volume ${ENTRYPOINT}:/entrypoint.sh \
            --env OP_DEVICE=$OP_DEVICE \
            --env OP_MASTER_PASSWORD="$OP_MASTER_PASSWORD" \
            --env OP_SUBDOMAIN=$OP_SUBDOMAIN \
            --env OP_EMAIL_ADDRESS=$OP_EMAIL_ADDRESS \
            --env OP_SECRET_KEY=$OP_SECRET_KEY \
            --env INTERNAL_DOMAIN_NAME=$INTERNAL_DOMAIN_NAME \
            --env REDIS_REDISINSIGHT_USERNAME=$REDIS_REDISINSIGHT_USERNAME \
            --env REDIS_REDISINSIGHT_PASSWORD=$REDIS_REDISINSIGHT_PASSWORD \
            --env REDIS_DATABASE_PASSWORD=$REDIS_DATABASE_PASSWORD \
            --entrypoint /entrypoint.sh \
            --cpus 0.01563 \
            --memory-reservation 61m \
            --memory 64m \
            ${ONE_PASSWORD_IMAGE}'
        '';
      };
      wantedBy = [ "${CONTAINERS_BACKEND}-redisinsight.service" ];
    };
  };

  services = {
    grafana-agent = {
      settings = {
        integrations = {
          redis_exporter = {
            enabled = true;
            scrape_interval = "1m";
            redis_addr = "${toString config.services.redis.servers.${REDIS_INSTANCE}.bind}:${toString config.services.redis.servers.${REDIS_INSTANCE}.port}";
            redis_user = "{{ redis_monitoring_database_username }}";
            redis_password = "{{ redis_monitoring_database_password }}";
          };
        };
      };
    };
  };
}
