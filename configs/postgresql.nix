{ config, pkgs, ... }:

let
  IP_ADDRESS = (import ./connection-parameters.nix).ip_address;
  CONTAINERS_BACKEND = config.virtualisation.oci-containers.backend;
  DOMAIN_NAME_INTERNAL = (import ./connection-parameters.nix).domain_name_internal;
in

{
  systemd.services = {
    postgresql-prepare = {
      before = [ "var-lib-postgresql.mount" ];
      serviceConfig = {
        Type = "oneshot";
      };
      script = "${pkgs.coreutils}/bin/mkdir -p /mnt/ssd/data-stores";
      wantedBy = [ "var-lib-postgresql.mount" ];
    };
  };

  fileSystems."/var/lib/postgresql" = {
    device = "/mnt/ssd/data-stores/postgresql";
    options = [
      "bind"
      "x-systemd.before=postgresql.service"
      "x-systemd.wanted-by=postgresql.service"
    ];
  };

  services = {
    postgresql = {
      enable = true;
      package = pkgs.postgresql_14;
      enableTCPIP = true;
      port = 5432;
      authentication = pkgs.lib.mkForce ''
        # TYPE  DATABASE        USER            ADDRESS                 METHOD

        # "local" is for Unix domain socket connections only
        local   all             all                                     peer
        # IPv4 local connections:
        host    all             all             ${IP_ADDRESS}/32           md5
        # IPv4 ${CONTAINERS_BACKEND} connections
        host    all             all             172.17.0.0/16           md5
      '';
      settings = {
        max_connections = 60;               # (change requires restart)
        shared_buffers = "512MB";           # min 128kB (change requires restart)
        huge_pages = "off";                 # on, off, or try (change requires restart)
        work_mem = "2184kB";                # min 64kB
        maintenance_work_mem = "128MB";     # min 1MB
        effective_io_concurrency = 200;     # 1-1000; 0 disables prefetching
        wal_buffers = "16MB";               # min 32kB, -1 sets based on shared_buffers (change requires restart)
        checkpoint_completion_target = 0.9; # checkpoint target duration, 0.0 - 1.0
        max_wal_size = "4GB";
        min_wal_size = "1GB";
        random_page_cost = 1.1;             # measured on an arbitrary scale
        effective_cache_size = "1536MB";
        default_statistics_target = 100;    # range 1-10000
      };
    };
  };

  systemd.services = {
    postgresql = {
      serviceConfig = {
        CPUQuota = "6%";
        MemoryHigh = "1946M";
        MemoryMax = "2048M";
      };
    };
  };

  networking = {
    firewall = {
      allowedTCPPorts = [ 5432 ];
    };
  };

  sops.secrets = {
    "pgadmin/postgres/envs" = {
      mode = "0400";
      owner = config.users.users.root.name;
      group = config.users.users.root.group;
    };
  };

  systemd.services = {
    pgadmin-postgres = {
      after = [ "postgresql.service" ];
      before = [ "${CONTAINERS_BACKEND}-pgadmin.service" ];
      serviceConfig = {
        Type = "oneshot";
        EnvironmentFile = config.sops.secrets."pgadmin/postgres/envs".path;
      };
      script = ''
        while ! ${pkgs.netcat}/bin/nc -w 1 -v -z ${IP_ADDRESS} ${toString config.services.postgresql.port}; do
          ${pkgs.coreutils}/bin/echo "Waiting for PostgreSQL availability."
          ${pkgs.coreutils}/bin/sleep 1
        done

        ${pkgs.sudo}/bin/sudo -u postgres ${pkgs.postgresql_14}/bin/psql --variable=ON_ERROR_STOP=1 <<-EOSQL 2> /dev/null
          DO
          \$do$
          BEGIN
              IF NOT EXISTS (
                  SELECT FROM pg_catalog.pg_roles
                  WHERE rolname = '$POSTGRESQL_USERNAME_PGADMIN'
              )
              THEN
                  CREATE ROLE $POSTGRESQL_USERNAME_PGADMIN WITH
                      LOGIN
                      NOINHERIT
                      CONNECTION LIMIT -1
                      ENCRYPTED PASSWORD '$POSTGRESQL_PASSWORD_PGADMIN';
                  RAISE NOTICE 'Role "$POSTGRESQL_USERNAME_PGADMIN" created successfully.';
              ELSE
                  ALTER ROLE $POSTGRESQL_USERNAME_PGADMIN WITH
                      LOGIN
                      NOINHERIT
                      CONNECTION LIMIT -1
                      ENCRYPTED PASSWORD '$POSTGRESQL_PASSWORD_PGADMIN';
                  RAISE NOTICE 'Role "$POSTGRESQL_USERNAME_PGADMIN" updated successfully.';
              END IF;
          END
          \$do$;

          GRANT CONNECT ON DATABASE postgres TO $POSTGRESQL_USERNAME_PGADMIN;
        EOSQL
      '';
      wantedBy = [
        "postgresql.service"
        "${CONTAINERS_BACKEND}-pgadmin.service"
      ];
    };
  };

  sops.secrets = {
    "pgadmin/application/envs" = {
      mode = "0400";
      owner = config.users.users.root.name;
      group = config.users.users.root.group;
    };
  };

  virtualisation = {
    oci-containers = {
      containers = {
        pgadmin = {
          autoStart = true;
          ports = [ "127.0.0.1:5050:5050" ];
          environmentFiles = [
            config.sops.secrets."pgadmin/application/envs".path
            config.sops.secrets."pgadmin/postgres/envs".path
          ];
          environment = {
            PGADMIN_DISABLE_POSTFIX = "True";
            PGADMIN_LISTEN_ADDRESS = "0.0.0.0";
            PGADMIN_LISTEN_PORT = "5050";
            PGADMIN_SERVER_JSON_FILE = "/var/lib/pgadmin/servers.json";
          };
          entrypoint = "/bin/sh";
          extraOptions = [
            "--cpus=0.0625"
            "--memory-reservation=243m"
            "--memory=256m"
          ];
          image = (import /etc/nixos/variables.nix).pgadmin_image;
          cmd = let
            SERVERS = ''
              {
                  \"Servers\": {
                      \"1\": {
                          \"Name\": \"Local\",
                          \"Group\": \"Servers\",
                          \"Host\": \"${IP_ADDRESS}\",
                          \"Port\": ${toString config.services.postgresql.port},
                          \"MaintenanceDB\": \"postgres\",
                          \"Username\": \"$POSTGRESQL_USERNAME_PGADMIN\",
                          \"PassFile\": \"/.pgpass\"
                      }
                  }
              }
            '';
            PG_PASS = "${IP_ADDRESS}:${toString config.services.postgresql.port}:postgres:$POSTGRESQL_USERNAME_PGADMIN:$POSTGRESQL_PASSWORD_PGADMIN";
          in [
            "-c" "
              echo \"${SERVERS}\" > /var/lib/pgadmin/servers.json
              export HOME_DIR=$(echo $PGADMIN_DEFAULT_EMAIL | sed 's/@/_/')

              mkdir -p /var/lib/pgadmin/storage/$HOME_DIR
              chmod 0700 /var/lib/pgadmin/storage/$HOME_DIR

              echo \"${PG_PASS}\" > /var/lib/pgadmin/storage/$HOME_DIR/.pgpass
              chmod 0600 /var/lib/pgadmin/storage/$HOME_DIR/.pgpass

              /entrypoint.sh
            "
          ];
        };
      };
    };
  };

  services = {
    nginx = {
      virtualHosts.${DOMAIN_NAME_INTERNAL} = {
        locations."/pgadmin4/" = {
          extraConfig = ''
            proxy_set_header X-Script-Name /pgadmin4;
            proxy_set_header X-Scheme $scheme;
            proxy_set_header Host $host;
            proxy_redirect off;
          '';
          proxyPass = "http://127.0.0.1:${config.virtualisation.oci-containers.containers.pgadmin.environment.PGADMIN_LISTEN_PORT}/";
        };
      };
    };
  };

  sops.secrets = {
    "postgres/grafana_agent/envs" = {
      mode = "0400";
      owner = config.users.users.root.name;
      group = config.users.users.root.group;
    };
  };

  systemd.services = {
    grafana-agent-postgres = {
      after = [ "postgresql.service" ];
      before = [ "grafana-agent.service" ];
      serviceConfig = {
        Type = "oneshot";
        EnvironmentFile = config.sops.secrets."postgres/grafana_agent/envs".path;
      };
      script = ''
        while ! ${pkgs.netcat}/bin/nc -w 1 -v -z ${IP_ADDRESS} ${toString config.services.postgresql.port}; do
          ${pkgs.coreutils}/bin/echo "Waiting for PostgreSQL availability."
          ${pkgs.coreutils}/bin/sleep 1
        done

        ${pkgs.sudo}/bin/sudo -u postgres ${pkgs.postgresql_14}/bin/psql --variable=ON_ERROR_STOP=1 <<-EOSQL 2> /dev/null
          DO
          \$do$
          BEGIN
              IF NOT EXISTS (
                  SELECT FROM pg_catalog.pg_roles
                  WHERE rolname = '$POSTGRESQL_USERNAME_GRAFANA_AGENT'
              )
              THEN
                  CREATE ROLE $POSTGRESQL_USERNAME_GRAFANA_AGENT WITH
                      LOGIN
                      NOINHERIT
                      CONNECTION LIMIT -1
                      ENCRYPTED PASSWORD '$POSTGRESQL_PASSWORD_GRAFANA_AGENT';
                  RAISE NOTICE 'Role "$POSTGRESQL_USERNAME_GRAFANA_AGENT" created successfully.';
              ELSE
                  ALTER ROLE $POSTGRESQL_USERNAME_GRAFANA_AGENT WITH
                      LOGIN
                      NOINHERIT
                      CONNECTION LIMIT -1
                      ENCRYPTED PASSWORD '$POSTGRESQL_PASSWORD_GRAFANA_AGENT';
                  RAISE NOTICE 'Role "$POSTGRESQL_USERNAME_GRAFANA_AGENT" updated successfully.';
              END IF;
          END
          \$do$;

          GRANT pg_monitor TO $POSTGRESQL_USERNAME_GRAFANA_AGENT;
        EOSQL
      '';
      wantedBy = [
        "postgresql.service"
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
    postgresql-1password = {
      after = [ "${CONTAINERS_BACKEND}-pgadmin.service" ];
      preStart = "${pkgs.coreutils}/bin/sleep $((RANDOM % 27))";
      serviceConfig = {
        Type = "oneshot";
        EnvironmentFile = [
          config.sops.secrets."1password/application/envs".path
          config.sops.secrets."pgadmin/application/envs".path
          config.sops.secrets."pgadmin/postgres/envs".path
          config.sops.secrets."postgres/grafana_agent/envs".path
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

        ${pkgs._1password}/bin/op item get PostgreSQL \
          --vault Server \
          --session $SESSION_TOKEN > /dev/null

        if [ $? != 0 ]
        then
          ${pkgs._1password}/bin/op item template get Database --session $SESSION_TOKEN | ${pkgs._1password}/bin/op item create --vault Server - \
            --title PostgreSQL \
            website[url]=http://${DOMAIN_NAME_INTERNAL}/pgadmin4 \
            username=$PGADMIN_DEFAULT_EMAIL \
            password=$PGADMIN_DEFAULT_PASSWORD \
            'DB connection command'.pgAdmin[password]="PGPASSWORD='$POSTGRESQL_PASSWORD_PGADMIN' psql -h ${IP_ADDRESS} -p ${toString config.services.postgresql.port} -U $POSTGRESQL_USERNAME_PGADMIN postgres" \
            'DB connection command'.'Grafana Agent'[password]="PGPASSWORD='$POSTGRESQL_PASSWORD_GRAFANA_AGENT' psql -h ${IP_ADDRESS} -p ${toString config.services.postgresql.port} -U $POSTGRESQL_USERNAME_GRAFANA_AGENT postgres" \
            --session $SESSION_TOKEN > /dev/null
          ${pkgs.coreutils}/bin/echo "Item created successfully."
        else
          ${pkgs._1password}/bin/op item edit PostgreSQL \
            --vault Server \
            website[url]=http://${DOMAIN_NAME_INTERNAL}/pgadmin4 \
            username=$PGADMIN_DEFAULT_EMAIL \
            password=$PGADMIN_DEFAULT_PASSWORD \
            'DB connection command'.pgAdmin[password]="PGPASSWORD='$POSTGRESQL_PASSWORD_PGADMIN' psql -h ${IP_ADDRESS} -p ${toString config.services.postgresql.port} -U $POSTGRESQL_USERNAME_PGADMIN postgres" \
            'DB connection command'.'Grafana Agent'[password]="PGPASSWORD='$POSTGRESQL_PASSWORD_GRAFANA_AGENT' psql -h ${IP_ADDRESS} -p ${toString config.services.postgresql.port} -U $POSTGRESQL_USERNAME_GRAFANA_AGENT postgres" \
            --session $SESSION_TOKEN > /dev/null
          ${pkgs.coreutils}/bin/echo "Item updated successfully."
        fi
      '';
      wantedBy = [ "${CONTAINERS_BACKEND}-pgadmin.service" ];
    };
  };

  sops.secrets = {
    "postgres/grafana_agent/file/username" = {
      mode = "0400";
      owner = config.users.users.root.name;
      group = config.users.users.root.group;
    };
  };

  sops.secrets = {
    "postgres/grafana_agent/file/password" = {
      mode = "0400";
      owner = config.users.users.root.name;
      group = config.users.users.root.group;
    };
  };

  services = {
    grafana-agent = {
      credentials = {
        POSTGRESQL_USERNAME_GRAFANA_AGENT = config.sops.secrets."postgres/grafana_agent/file/username".path;
        POSTGRESQL_PASSWORD_GRAFANA_AGENT = config.sops.secrets."postgres/grafana_agent/file/password".path;
      };

      settings = {
        logs = {
          configs = [{
            name = "postgresql";
            clients = [{
              url = "http://${config.services.loki.configuration.server.http_listen_address}:${toString config.services.loki.configuration.server.http_listen_port}/loki/api/v1/push";
            }];
            positions = {
              filename = "/var/lib/private/grafana-agent/positions/postgresql.yml";
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
                  regex = "(postgresql-prepare|var-lib-postgresql|postgresql|pgadmin-postgres|${CONTAINERS_BACKEND}-pgadmin|grafana-agent-postgres|postgresql-1password).(service|mount)";
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
          postgres_exporter = {
            enabled = true;
            scrape_interval = "1m";
            scrape_timeout = "10s";
            data_source_names = [ "postgresql://\${POSTGRESQL_USERNAME_GRAFANA_AGENT}:\${POSTGRESQL_PASSWORD_GRAFANA_AGENT}@${IP_ADDRESS}:${toString config.services.postgresql.port}/postgres?sslmode=disable" ];
            autodiscover_databases = true;
          };
        };
      };
    };
  };
}
