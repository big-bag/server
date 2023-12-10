{ config, pkgs, ... }:

let
  IP_ADDRESS = (import ./connection-parameters.nix).ip_address;
in

{
  sops.secrets = {
    "postgres_exporter/postgres/envs" = {
      mode = "0400";
      owner = config.users.users.root.name;
      group = config.users.users.root.group;
    };
  };

  systemd.services = {
    postgres-exporter-postgres = {
      after = [ "postgresql.service" ];
      before = [ "grafana-agent.service" ];
      serviceConfig = {
        Type = "oneshot";
        EnvironmentFile = config.sops.secrets."postgres_exporter/postgres/envs".path;
      };
      script = ''
        while ! ${pkgs.netcat}/bin/nc -w 1 -v -z ${IP_ADDRESS} ${toString config.services.postgresql.port}
        do
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

          SELECT format('
              GRANT CONNECT
                  ON DATABASE %I
                  TO $POSTGRESQL_USERNAME
              ', datname)
              FROM pg_database
              WHERE NOT datistemplate
                  AND datallowconn;
          \gexec
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
    postgres-exporter-1password = {
      after = [ "postgres-exporter-postgres.service" ];
      preStart = "${pkgs.coreutils}/bin/sleep $((RANDOM % 36))";
      serviceConfig = {
        Type = "oneshot";
        EnvironmentFile = [
          config.sops.secrets."1password/application/envs".path
          config.sops.secrets."postgres_exporter/postgres/envs".path
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
      wantedBy = [ "postgres-exporter-postgres.service" ];
    };
  };

  sops.secrets = {
    "postgres_exporter/postgres/file/username" = {
      mode = "0400";
      owner = config.users.users.root.name;
      group = config.users.users.root.group;
    };
  };

  sops.secrets = {
    "postgres_exporter/postgres/file/password" = {
      mode = "0400";
      owner = config.users.users.root.name;
      group = config.users.users.root.group;
    };
  };

  services = {
    grafana-agent = {
      credentials = {
        POSTGRESQL_USERNAME = config.sops.secrets."postgres_exporter/postgres/file/username".path;
        POSTGRESQL_PASSWORD = config.sops.secrets."postgres_exporter/postgres/file/password".path;
      };

      settings = {
        logs = {
          configs = [{
            name = "postgres-exporter";
            clients = [{
              url = "http://${config.services.loki.configuration.server.http_listen_address}:${toString config.services.loki.configuration.server.http_listen_port}/loki/api/v1/push";
            }];
            positions = {
              filename = "/var/lib/private/grafana-agent/positions/postgres-exporter.yml";
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
                  regex = "(postgres-exporter-postgres|postgres-exporter-1password).service";
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
