{ config, pkgs, ... }:

let
  IP_ADDRESS = (import ./connection-parameters.nix).ip_address;
  CONTAINERS_BACKEND = config.virtualisation.oci-containers.backend;
  DOMAIN_NAME_INTERNAL = (import ./connection-parameters.nix).domain_name_internal;
in

{
  systemd.services = {
    grafana-prepare = {
      before = [ "grafana.service" ];
      serviceConfig = {
        Type = "oneshot";
      };
      script = "${pkgs.coreutils}/bin/mkdir -p /mnt/ssd/monitoring";
      wantedBy = [ "grafana.service" ];
    };
  };

  sops.secrets = {
    "grafana/postgres/envs" = {
      mode = "0400";
      owner = config.users.users.root.name;
      group = config.users.users.root.group;
    };
  };

  systemd.services = {
    grafana-postgres = {
      after = [ "postgresql.service" ];
      before = [ "grafana.service" ];
      serviceConfig = {
        Type = "oneshot";
        EnvironmentFile = config.sops.secrets."grafana/postgres/envs".path;
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
                  AND datallowconn
                  AND datname <> 'postgres';
          \gexec

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
        "grafana.service"
      ];
    };
  };

  sops.secrets = {
    "redis/application/envs" = {
      mode = "0400";
      owner = config.users.users.root.name;
      group = config.users.users.root.group;
    };
  };

  sops.secrets = {
    "grafana/redis/envs" = {
      mode = "0400";
      owner = config.users.users.root.name;
      group = config.users.users.root.group;
    };
  };

  systemd.services = {
    grafana-redis = {
      after = [ "${CONTAINERS_BACKEND}-redis.service" ];
      before = [ "grafana.service" ];
      serviceConfig = {
        Type = "oneshot";
        EnvironmentFile = [
          config.sops.secrets."redis/application/envs".path
          config.sops.secrets."grafana/redis/envs".path
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
                  +ping \
                  +client|list \
                  +cluster|info \
                  +cluster|nodes \
                  +get \
                  +hget \
                  +hgetall \
                  +hkeys \
                  +hlen \
                  +hmget \
                  +info \
                  +llen \
                  +scard \
                  +slowlog \
                  +smembers \
                  +ttl \
                  +type \
                  +xinfo \
                  +xlen \
                  +xrange \
                  +xrevrange \
                  +zrange \
                  +scan \
                  +memory|usage \
                  +json.arrlen \
                  +json.get \
                  +json.objkeys \
                  +json.objlen \
                  +json.type \
                  +ft.info \
                  +ft.search \
                  +ts.get \
                  +ts.info \
                  +ts.mget \
                  +ts.mrange \
                  +ts.queryindex \
                  +ts.range \
                  +dbsize \
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
        "grafana.service"
      ];
    };
  };

  sops.secrets = {
    "grafana/application/envs" = {
      mode = "0400";
      owner = config.users.users.root.name;
      group = config.users.users.root.group;
    };
  };

  services = {
    grafana = {
      enable = true;
      dataDir = "/mnt/ssd/monitoring/grafana";
      settings = {
        server = {
          protocol = "http";
          http_addr = "127.0.0.1";
          http_port = 3000;
          domain = "${DOMAIN_NAME_INTERNAL}";
          root_url = "%(protocol)s://%(domain)s:%(http_port)s/grafana/";
          enable_gzip = true;
        };
        security = {
          admin_user = "$__env{USERNAME}";
          admin_password = "$__env{PASSWORD}";
        };
      };
      declarativePlugins = with pkgs.grafanaPlugins; [ redis-datasource ];
      provision = {
        enable = true;
        datasources.path = pkgs.writeTextFile {
          name = "datasources.yml";
          text = ''
            apiVersion: 1

            datasources:
              - name: Mimir
                type: prometheus
                access: proxy
                version: 1
                orgId: 1
                uid: $DATASOURCE_UID_MIMIR
                isDefault: false
                url: http://127.0.0.1:9009/mimir/prometheus
                jsonData:
                  manageAlerts: true
                  timeInterval: 1m # 'Scrape interval' in Grafana UI, defaults to 15s
                  httpMethod: POST
                  prometheusType: Mimir
                editable: true

              - name: Prometheus
                type: prometheus
                access: proxy
                version: 1
                orgId: 1
                uid: $DATASOURCE_UID_PROMETHEUS
                isDefault: false
                url: http://${config.services.prometheus.listenAddress}:${toString config.services.prometheus.port}/prometheus
                jsonData:
                  manageAlerts: true
                  timeInterval: ${config.services.prometheus.globalConfig.scrape_interval} # 'Scrape interval' in Grafana UI, defaults to 15s
                  httpMethod: POST
                  prometheusType: Prometheus
                editable: true

              - name: Loki
                type: loki
                access: proxy
                version: 1
                orgId: 1
                uid: $DATASOURCE_UID_LOKI
                isDefault: true
                url: http://${config.services.loki.configuration.server.http_listen_address}:${toString config.services.loki.configuration.server.http_listen_port}
                jsonData:
                  manageAlerts: true
                  maxLines: 1000
                editable: true

              - name: Mattermost
                type: postgres
                access: proxy
                version: 1
                orgId: 1
                uid: $DATASOURCE_UID_POSTGRESQL_MATTERMOST
                isDefault: false
                url: ${IP_ADDRESS}:${toString config.services.postgresql.port}
                user: $POSTGRESQL_USERNAME
                jsonData:
                  database: $POSTGRESQL_DATABASE_MATTERMOST
                  sslmode: disable # disable/require/verify-ca/verify-full
                  maxOpenConns: 100
                  maxIdleConns: 100
                  maxIdleConnsAuto: true
                  connMaxLifetime: 14400
                  postgresVersion: 1400 # 903=9.3, 904=9.4, 905=9.5, 906=9.6, 1000=10
                  timescaledb: false
                secureJsonData:
                  password: $POSTGRESQL_PASSWORD
                editable: true

              - name: GitLab-Redis
                type: redis-datasource
                access: proxy
                version: 1
                orgId: 1
                uid: $DATASOURCE_UID_REDIS_GITLAB
                isDefault: false
                url: redis://${IP_ADDRESS}:6379
                jsonData:
                  client: standalone
                  acl: true
                  user: $REDIS_USERNAME
                  poolSize: 5
                  timeout: 10
                  pingInterval: 0
                  pipelineWindow: 0
                  tlsAuth: false
                secureJsonData:
                  password: $REDIS_PASSWORD_CLI
                editable: true

              - name: GitLab-Postgres
                type: postgres
                access: proxy
                version: 1
                orgId: 1
                uid: $DATASOURCE_UID_POSTGRESQL_GITLAB
                isDefault: false
                url: ${IP_ADDRESS}:${toString config.services.postgresql.port}
                user: $POSTGRESQL_USERNAME
                jsonData:
                  database: $POSTGRESQL_DATABASE_GITLAB
                  sslmode: disable # disable/require/verify-ca/verify-full
                  maxOpenConns: 100
                  maxIdleConns: 100
                  maxIdleConnsAuto: true
                  connMaxLifetime: 14400
                  postgresVersion: 1400 # 903=9.3, 904=9.4, 905=9.5, 906=9.6, 1000=10
                  timescaledb: false
                secureJsonData:
                  password: $POSTGRESQL_PASSWORD
                editable: true
          '';
        };
        dashboards.path = pkgs.writeTextFile {
          name = "dashboards.yml";
          text = ''
            apiVersion: 1

            providers:
              - name: Dashboards
                orgId: 1
                type: file
                disableDeletion: true
                updateIntervalSeconds: 30
                allowUiUpdates: true
                options:
                  path: /mnt/ssd/monitoring/grafana-dashboards
                  foldersFromFilesStructure: true
          '';
        };
      };
    };
  };

  systemd.services = {
    grafana = {
      environment = {
        GF_LOG_LEVEL = "info"; # Options are “debug”, “info”, “warn”, “error”, and “critical”. Default is info.
      };
      serviceConfig = {
        EnvironmentFile = [
          config.sops.secrets."grafana/application/envs".path
          config.sops.secrets."grafana/postgres/envs".path
          config.sops.secrets."grafana/redis/envs".path
        ];
        CPUQuota = "6%";
        MemoryHigh = "1946M";
        MemoryMax = "2048M";
      };
    };
  };

  services = {
    nginx = {
      upstreams."grafana" = {
        servers = let
          GRAFANA_ADDRESS = "${config.services.grafana.settings.server.http_addr}:${toString config.services.grafana.settings.server.http_port}";
        in { "${GRAFANA_ADDRESS}" = {}; };
      };

      virtualHosts.${DOMAIN_NAME_INTERNAL} = {
        locations."/grafana/" = {
          extraConfig = ''
            rewrite ^/grafana/(.*) /$1 break;
            proxy_set_header Host $host;
          '';
          proxyPass = "http://grafana";
        };

        # Proxy Grafana Live WebSocket connections.
        locations."/grafana/api/live/" = {
          extraConfig = ''
            rewrite ^/grafana/(.*) /$1 break;
            proxy_http_version 1.1;

            proxy_set_header Upgrade $http_upgrade;
            proxy_set_header Connection $connection_upgrade;
            proxy_set_header Host $host;
          '';
          proxyPass = "http://grafana";
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
    grafana-1password = {
      after = [ "grafana.service" ];
      preStart = "${pkgs.coreutils}/bin/sleep $((RANDOM % 33))";
      serviceConfig = {
        Type = "oneshot";
        EnvironmentFile = [
          config.sops.secrets."1password/application/envs".path
          config.sops.secrets."grafana/application/envs".path
          config.sops.secrets."grafana/postgres/envs".path
          config.sops.secrets."grafana/redis/envs".path
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

        ${pkgs._1password}/bin/op item get Grafana \
          --vault Server \
          --session $SESSION_TOKEN > /dev/null

        if [ $? != 0 ]
        then
          ${pkgs._1password}/bin/op item template get Login --session $SESSION_TOKEN | ${pkgs._1password}/bin/op item create --vault Server - \
            --title Grafana \
            --url https://${DOMAIN_NAME_INTERNAL}/grafana \
            username=$USERNAME \
            password=$PASSWORD \
            Postgres.'Connection command to Mattermost database'[password]="PGPASSWORD='$POSTGRESQL_PASSWORD' psql -h ${IP_ADDRESS} -p ${toString config.services.postgresql.port} -U $POSTGRESQL_USERNAME $POSTGRESQL_DATABASE_MATTERMOST" \
            Postgres.'Connection command to GitLab database'[password]="PGPASSWORD='$POSTGRESQL_PASSWORD' psql -h ${IP_ADDRESS} -p ${toString config.services.postgresql.port} -U $POSTGRESQL_USERNAME $POSTGRESQL_DATABASE_GITLAB" \
            Redis.'Connection command'[password]="sudo docker exec -ti redis redis-cli -u 'redis://$REDIS_USERNAME:$REDIS_PASSWORD_1PASSWORD@127.0.0.1:6379'" \
            --session $SESSION_TOKEN > /dev/null
          ${pkgs.coreutils}/bin/echo "Item created successfully."
        else
          ${pkgs._1password}/bin/op item edit Grafana \
            --vault Server \
            --url https://${DOMAIN_NAME_INTERNAL}/grafana \
            username=$USERNAME \
            password=$PASSWORD \
            Postgres.'Connection command to Mattermost database'[password]="PGPASSWORD='$POSTGRESQL_PASSWORD' psql -h ${IP_ADDRESS} -p ${toString config.services.postgresql.port} -U $POSTGRESQL_USERNAME $POSTGRESQL_DATABASE_MATTERMOST" \
            Postgres.'Connection command to GitLab database'[password]="PGPASSWORD='$POSTGRESQL_PASSWORD' psql -h ${IP_ADDRESS} -p ${toString config.services.postgresql.port} -U $POSTGRESQL_USERNAME $POSTGRESQL_DATABASE_GITLAB" \
            Redis.'Connection command'[password]="sudo docker exec -ti redis redis-cli -u 'redis://$REDIS_USERNAME:$REDIS_PASSWORD_1PASSWORD@127.0.0.1:6379'" \
            --session $SESSION_TOKEN > /dev/null
          ${pkgs.coreutils}/bin/echo "Item updated successfully."
        fi
      '';
      wantedBy = [ "grafana.service" ];
    };
  };

  services = {
    grafana-agent = {
      settings = {
        metrics = {
          configs = [{
            name = "grafana";
            scrape_configs = [{
              job_name = "grafana";
              scrape_interval = "1m";
              scrape_timeout = "10s";
              scheme = "http";
              static_configs = [{
                targets = [ "${config.services.grafana.settings.server.http_addr}:${toString config.services.grafana.settings.server.http_port}" ];
              }];
              metrics_path = "/metrics";
            }];
            remote_write = [{
              url = "http://127.0.0.1:9009/mimir/api/v1/push";
            }];
          }];
        };

        logs = {
          configs = [{
            name = "grafana";
            clients = [{
              url = "http://${config.services.loki.configuration.server.http_listen_address}:${toString config.services.loki.configuration.server.http_listen_port}/loki/api/v1/push";
            }];
            positions = {
              filename = "/var/lib/private/grafana-agent/positions/grafana.yml";
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
                  regex = "(grafana-prepare|grafana-postgres|grafana|grafana-1password).service";
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
