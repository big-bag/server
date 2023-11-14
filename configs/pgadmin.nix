{ config, pkgs, ... }:

let
  CONTAINERS_BACKEND = config.virtualisation.oci-containers.backend;
  IP_ADDRESS = (import ./connection-parameters.nix).ip_address;
  DOMAIN_NAME_INTERNAL = (import ./connection-parameters.nix).domain_name_internal;
in

{
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

          \connect postgres

          GRANT USAGE
              ON SCHEMA public
              TO $POSTGRESQL_USERNAME;

          CREATE EXTENSION IF NOT EXISTS dblink;

          DO
          \$$
          DECLARE
            database_name text;
            connection_string text;
            database_current text;
            database_schema text;

          BEGIN
              FOR database_name IN
                  SELECT datname
                      FROM pg_database
                      WHERE NOT datistemplate
                          AND datallowconn
                          AND datname <> 'postgres'
              LOOP
                  connection_string = 'dbname=' || database_name;

                  database_current = (
                      SELECT *
                          FROM dblink(connection_string, '
                              SELECT current_database()
                          ')
                          AS (output_data TEXT)
                  );
                  RAISE NOTICE 'Performing operations in the "%" database.', database_current;

                  FOR database_schema IN
                      SELECT *
                          FROM dblink(connection_string, '
                              SELECT schema_name
                              FROM information_schema.schemata
                              WHERE schema_name <> '''pg_toast'''
                                  AND schema_name <> '''pg_catalog'''
                                  AND schema_name <> '''information_schema'''
                          ')
                          AS (output_data TEXT)
                  LOOP
                      RAISE NOTICE 'Performing operations in the "%" schema.', database_schema;

                      PERFORM dblink_exec(connection_string, '
                          GRANT USAGE
                              ON SCHEMA '|| database_schema ||'
                              TO $POSTGRESQL_USERNAME
                      ');
                      PERFORM dblink_exec(connection_string, '
                          GRANT SELECT
                              ON ALL TABLES IN SCHEMA '|| database_schema ||'
                              TO $POSTGRESQL_USERNAME
                      ');
                      PERFORM dblink_exec(connection_string, '
                          ALTER DEFAULT PRIVILEGES
                              IN SCHEMA '|| database_schema ||'
                              GRANT SELECT
                                  ON TABLES
                                  TO $POSTGRESQL_USERNAME
                      ');
                  END LOOP;
              END LOOP;
          END
          \$$;
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
          image = (import ./variables.nix).pgadmin_image;
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
                          \"Username\": \"$POSTGRESQL_USERNAME\",
                          \"PassFile\": \"/.pgpass\"
                      }
                  }
              }
            '';
            PG_PASS = "${IP_ADDRESS}:${toString config.services.postgresql.port}:*:$POSTGRESQL_USERNAME:$POSTGRESQL_PASSWORD";
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
    "1password/application/envs" = {
      mode = "0400";
      owner = config.users.users.root.name;
      group = config.users.users.root.group;
    };
  };

  systemd.services = {
    pgadmin-1password = {
      after = [ "${CONTAINERS_BACKEND}-pgadmin.service" ];
      preStart = "${pkgs.coreutils}/bin/sleep $((RANDOM % 33))";
      serviceConfig = {
        Type = "oneshot";
        EnvironmentFile = [
          config.sops.secrets."1password/application/envs".path
          config.sops.secrets."pgadmin/application/envs".path
          config.sops.secrets."pgadmin/postgres/envs".path
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

        ${pkgs._1password}/bin/op item get pgAdmin \
          --vault Server \
          --session $SESSION_TOKEN > /dev/null

        if [ $? != 0 ]
        then
          ${pkgs._1password}/bin/op item template get Login --session $SESSION_TOKEN | ${pkgs._1password}/bin/op item create --vault Server - \
            --title pgAdmin \
            --url https://${DOMAIN_NAME_INTERNAL}/pgadmin4 \
            username=$PGADMIN_DEFAULT_EMAIL \
            password=$PGADMIN_DEFAULT_PASSWORD \
            Postgres.'Connection command'[password]="PGPASSWORD='$POSTGRESQL_PASSWORD' psql -h ${IP_ADDRESS} -p ${toString config.services.postgresql.port} -U $POSTGRESQL_USERNAME postgres" \
            --session $SESSION_TOKEN > /dev/null
          ${pkgs.coreutils}/bin/echo "Item created successfully."
        else
          ${pkgs._1password}/bin/op item edit pgAdmin \
            --vault Server \
            --url https://${DOMAIN_NAME_INTERNAL}/pgadmin4 \
            username=$PGADMIN_DEFAULT_EMAIL \
            password=$PGADMIN_DEFAULT_PASSWORD \
            Postgres.'Connection command'[password]="PGPASSWORD='$POSTGRESQL_PASSWORD' psql -h ${IP_ADDRESS} -p ${toString config.services.postgresql.port} -U $POSTGRESQL_USERNAME postgres" \
            --session $SESSION_TOKEN > /dev/null
          ${pkgs.coreutils}/bin/echo "Item updated successfully."
        fi
      '';
      wantedBy = [ "${CONTAINERS_BACKEND}-pgadmin.service" ];
    };
  };

  services = {
    grafana-agent = {
      settings = {
        logs = {
          configs = [{
            name = "pgadmin";
            clients = [{
              url = "http://${config.services.loki.configuration.server.http_listen_address}:${toString config.services.loki.configuration.server.http_listen_port}/loki/api/v1/push";
            }];
            positions = {
              filename = "/var/lib/private/grafana-agent/positions/pgadmin.yml";
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
                  regex = "(pgadmin-postgres|${CONTAINERS_BACKEND}-pgadmin|pgadmin-1password).service";
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
      };
    };
  };
}
