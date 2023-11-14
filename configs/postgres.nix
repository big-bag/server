{ config, pkgs, ... }:

let
  IP_ADDRESS = (import ./connection-parameters.nix).ip_address;
  CONTAINERS_BACKEND = config.virtualisation.oci-containers.backend;
in

{
  systemd.services = {
    postgres-prepare = {
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
        max_connections = 70;               # (change requires restart)
        shared_buffers = "512MB";           # min 128kB (change requires restart)
        huge_pages = "off";                 # on, off, or try (change requires restart)
        work_mem = "1872kB";                # min 64kB
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

  systemd.services = {
    postgres-configure = {
      after = [ "postgresql.service" ];
      serviceConfig = {
        Type = "oneshot";
      };
      script = ''
        while ! ${pkgs.netcat}/bin/nc -w 1 -v -z ${IP_ADDRESS} ${toString config.services.postgresql.port}; do
          ${pkgs.coreutils}/bin/echo "Waiting for Postgres availability."
          ${pkgs.coreutils}/bin/sleep 1
        done

        ${pkgs.sudo}/bin/sudo -u postgres ${pkgs.postgresql_14}/bin/psql --variable=ON_ERROR_STOP=1 <<-EOSQL 2> /dev/null
          REVOKE CONNECT
              ON DATABASE postgres
              FROM PUBLIC;

          \connect postgres

          REVOKE ALL PRIVILEGES
              ON SCHEMA public
              FROM PUBLIC;
        EOSQL
      '';
      wantedBy = [ "postgresql.service" ];
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
          ${pkgs.coreutils}/bin/echo "Waiting for Postgres availability."
          ${pkgs.coreutils}/bin/sleep 1
        done

        ${pkgs.sudo}/bin/sudo -u postgres ${pkgs.postgresql_14}/bin/psql --variable=ON_ERROR_STOP=1 <<-EOSQL 2> /dev/null
          DO
          \$$
          BEGIN
              IF NOT EXISTS (
                  SELECT FROM pg_catalog.pg_roles
                  WHERE rolname = '$POSTGRESQL_USERNAME'
              )
              THEN
                  CREATE ROLE $POSTGRESQL_USERNAME WITH
                      LOGIN
                      NOINHERIT
                      CONNECTION LIMIT -1
                      ENCRYPTED PASSWORD '$POSTGRESQL_PASSWORD';
                  RAISE NOTICE 'Role "$POSTGRESQL_USERNAME" created successfully.';
              ELSE
                  ALTER ROLE $POSTGRESQL_USERNAME WITH
                      LOGIN
                      NOINHERIT
                      CONNECTION LIMIT -1
                      ENCRYPTED PASSWORD '$POSTGRESQL_PASSWORD';
                  RAISE NOTICE 'Role "$POSTGRESQL_USERNAME" updated successfully.';
              END IF;
          END
          \$$;

          GRANT pg_monitor TO $POSTGRESQL_USERNAME;
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
    postgres-1password = {
      after = [ "postgresql.service" ];
      preStart = "${pkgs.coreutils}/bin/sleep $((RANDOM % 33))";
      serviceConfig = {
        Type = "oneshot";
        EnvironmentFile = [
          config.sops.secrets."1password/application/envs".path
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

        ${pkgs._1password}/bin/op item get Postgres \
          --vault Server \
          --session $SESSION_TOKEN > /dev/null

        if [ $? != 0 ]
        then
          ${pkgs._1password}/bin/op item template get Database --session $SESSION_TOKEN | ${pkgs._1password}/bin/op item create --vault Server - \
            --title Postgres \
            'Grafana Agent'.username[text]=$POSTGRESQL_USERNAME \
            'Grafana Agent'.password[password]=$POSTGRESQL_PASSWORD \
            --session $SESSION_TOKEN > /dev/null
          ${pkgs.coreutils}/bin/echo "Item created successfully."
        else
          ${pkgs._1password}/bin/op item edit Postgres \
            --vault Server \
            'Grafana Agent'.username[text]=$POSTGRESQL_USERNAME \
            'Grafana Agent'.password[password]=$POSTGRESQL_PASSWORD \
            --session $SESSION_TOKEN > /dev/null
          ${pkgs.coreutils}/bin/echo "Item updated successfully."
        fi
      '';
      wantedBy = [ "postgresql.service" ];
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
        POSTGRESQL_USERNAME = config.sops.secrets."postgres/grafana_agent/file/username".path;
        POSTGRESQL_PASSWORD = config.sops.secrets."postgres/grafana_agent/file/password".path;
      };

      settings = {
        logs = {
          configs = [{
            name = "postgres";
            clients = [{
              url = "http://${config.services.loki.configuration.server.http_listen_address}:${toString config.services.loki.configuration.server.http_listen_port}/loki/api/v1/push";
            }];
            positions = {
              filename = "/var/lib/private/grafana-agent/positions/postgres.yml";
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
                  regex = "(postgres-prepare|var-lib-postgresql|postgresql|grafana-agent-postgres|postgres-1password).(service|mount)";
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
            data_source_names = [ "postgresql://\${POSTGRESQL_USERNAME}:\${POSTGRESQL_PASSWORD}@${IP_ADDRESS}:${toString config.services.postgresql.port}/postgres?sslmode=disable" ];
            autodiscover_databases = true;
          };
        };
      };
    };
  };
}
