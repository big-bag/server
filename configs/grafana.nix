{ config, pkgs, ... }:

let
  CONTAINERS_BACKEND = config.virtualisation.oci-containers.backend;
  MINIO_BUCKET = "grafana";
  IP_ADDRESS = (import ./connection-parameters.nix).ip_address;
  DOMAIN_NAME_INTERNAL = (import ./connection-parameters.nix).domain_name_internal;
in

{
  sops.secrets = {
    "minio/application/envs" = {
      mode = "0400";
      owner = config.users.users.root.name;
      group = config.users.users.root.group;
    };
  };

  sops.secrets = {
    "grafana/minio/envs" = {
      mode = "0400";
      owner = config.users.users.root.name;
      group = config.users.users.root.group;
    };
  };

  systemd.services = {
    grafana-minio = {
      before = [ "${CONTAINERS_BACKEND}-grafana.service" ];
      serviceConfig = {
        Type = "oneshot";
        EnvironmentFile = [
          config.sops.secrets."minio/application/envs".path
          config.sops.secrets."grafana/minio/envs".path
        ];
      };
      environment = {
        ALIAS = "local";
      };
      path = [ pkgs.getent ];
      script = let
        policy_json = pkgs.writeTextFile {
          name = "policy.json";
          text = ''
            {
                "Version": "2012-10-17",
                "Statement": [
                    {
                        "Effect": "Allow",
                        "Action": [
                            "s3:PutObject",
                            "s3:GetObject",
                            "s3:DeleteObject"
                        ],
                        "Resource": "arn:aws:s3:::${MINIO_BUCKET}/*"
                    }
                ]
            }
          '';
        };
      in ''
        set +e

        # args: host port
        check_port_is_open() {
          local exit_status_code
          ${pkgs.curl}/bin/curl --silent --connect-timeout 1 --telnet-option "" telnet://"$1:$2" </dev/null
          exit_status_code=$?
          case $exit_status_code in
            49) return 0 ;;
            *) return "$exit_status_code" ;;
          esac
        }

        while true
        do
          check_port_is_open ${IP_ADDRESS} 9000
          if [ $? == 0 ]; then
            ${pkgs.minio-client}/bin/mc alias set $ALIAS http://${IP_ADDRESS}:9000 $MINIO_ROOT_USER $MINIO_ROOT_PASSWORD
            ${pkgs.minio-client}/bin/mc mb --ignore-existing $ALIAS/${MINIO_BUCKET}

            ${pkgs.minio-client}/bin/mc admin user svcacct info $ALIAS $MINIO_SERVICE_ACCOUNT_ACCESS_KEY

            if [ $? != 0 ]
            then
              ${pkgs.minio-client}/bin/mc admin user svcacct add \
                --access-key $MINIO_SERVICE_ACCOUNT_ACCESS_KEY \
                --secret-key $MINIO_SERVICE_ACCOUNT_SECRET_KEY \
                --policy ${policy_json} \
                --comment grafana \
                $ALIAS \
                $MINIO_ROOT_USER > /dev/null
              ${pkgs.coreutils}/bin/echo "Service account created successfully \`$MINIO_SERVICE_ACCOUNT_ACCESS_KEY\`."
            else
              ${pkgs.minio-client}/bin/mc admin user svcacct edit \
                --secret-key $MINIO_SERVICE_ACCOUNT_SECRET_KEY \
                --policy ${policy_json} \
                $ALIAS \
                $MINIO_SERVICE_ACCOUNT_ACCESS_KEY
              ${pkgs.coreutils}/bin/echo "Service account updated successfully \`$MINIO_SERVICE_ACCOUNT_ACCESS_KEY\`."
            fi

            break
          fi
          ${pkgs.coreutils}/bin/echo "Waiting for MinIO availability."
          ${pkgs.coreutils}/bin/sleep 1
        done
      '';
      wantedBy = [ "${CONTAINERS_BACKEND}-grafana.service" ];
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
      before = [ "${CONTAINERS_BACKEND}-grafana.service" ];
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
        "${CONTAINERS_BACKEND}-grafana.service"
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
      before = [ "${CONTAINERS_BACKEND}-grafana.service" ];
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
              CLI_COMMAND=$(
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
                  +command \
                  allkeys \
                  on \
                  >$PASSWORD" |
                redis-cli
              )

              case "$CLI_COMMAND" in
                "OK" )
                  echo $CLI_COMMAND
                  exit 0
                ;;
                "ERR"* )
                  echo $CLI_COMMAND
                  exit 1
                ;;
              esac
            '
      '';
      wantedBy = [
        "${CONTAINERS_BACKEND}-redis.service"
        "${CONTAINERS_BACKEND}-grafana.service"
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

  sops.secrets = {
    "grafana/github/envs" = {
      mode = "0400";
      owner = config.users.users.root.name;
      group = config.users.users.root.group;
    };
  };

  virtualisation = {
    oci-containers = {
      containers = {
        grafana = {
          autoStart = true;
          ports = [ "127.0.0.1:3000:3000" ];
          volumes = let
            datasources_yml = pkgs.writeTextFile {
              name = "config.yml";
              text = ''
                apiVersion: 1

                datasources:
                  - name: GitHub
                    type: grafana-github-datasource
                    access: proxy
                    version: 1
                    orgId: 1
                    isDefault: false
                    jsonData:
                      owner: 'big-bag'
                      repository: 'server'
                    secureJsonData:
                      accessToken: $GITHUB_TOKEN
                    editable: true

                  - name: Mimir
                    type: prometheus
                    access: proxy
                    version: 1
                    orgId: 1
                    isDefault: false
                    url: http://${IP_ADDRESS}:9009/mimir/prometheus
                    jsonData:
                      manageAlerts: true
                      timeInterval: 1m # 'Scrape interval' in Grafana UI, defaults to 15s
                      httpMethod: POST
                      prometheusType: Mimir
                    editable: true

                  - name: Loki
                    type: loki
                    access: proxy
                    version: 1
                    orgId: 1
                    isDefault: true
                    url: http://${config.services.loki.configuration.server.http_listen_address}:${toString config.services.loki.configuration.server.http_listen_port}
                    jsonData:
                      manageAlerts: true
                      maxLines: 1000
                    editable: true

                  - name: Prometheus
                    type: prometheus
                    access: proxy
                    version: 1
                    orgId: 1
                    isDefault: false
                    url: http://${config.services.prometheus.listenAddress}:${toString config.services.prometheus.port}/prometheus
                    jsonData:
                      manageAlerts: true
                      timeInterval: ${config.services.prometheus.globalConfig.scrape_interval} # 'Scrape interval' in Grafana UI, defaults to 15s
                      httpMethod: POST
                      prometheusType: Prometheus
                    editable: true

                  - name: Mattermost
                    type: postgres
                    access: proxy
                    version: 1
                    orgId: 1
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

            plugins_yml = pkgs.writeTextFile {
              name = "config.yml";
              text = ''
                apiVersion: 1

                apps:
                  - type: redis-app
                    org_id: 1
                    disabled: false
              '';
            };

            dashboards_yml = pkgs.writeTextFile {
              name = "config.yml";
              text = ''
                apiVersion: 1

                providers:
                  - name: Dashboards
                    orgId: 1
                    type: file
                    disableDeletion: false
                    updateIntervalSeconds: 60
                    allowUiUpdates: true
                    options:
                      path: /var/lib/grafana/dashboards
                      foldersFromFilesStructure: true
              '';
            };
          in [
            "${datasources_yml}:/etc/grafana/provisioning/datasources/config.yml:ro"
            "${plugins_yml}:/etc/grafana/provisioning/plugins/config.yml:ro"
            "/mnt/ssd/monitoring/grafana-dashboards:/var/lib/grafana/dashboards:ro"
            "${dashboards_yml}:/etc/grafana/provisioning/dashboards/config.yml:ro"
          ];
          environmentFiles = [
            config.sops.secrets."grafana/application/envs".path
            config.sops.secrets."grafana/github/envs".path
            config.sops.secrets."grafana/minio/envs".path
            config.sops.secrets."grafana/postgres/envs".path
            config.sops.secrets."grafana/redis/envs".path
          ];
          environment = {
            GF_SERVER_PROTOCOL = "http";
            GF_SERVER_HTTP_ADDR = "0.0.0.0";
            GF_SERVER_HTTP_PORT = "3000";
            GF_SERVER_DOMAIN = "${DOMAIN_NAME_INTERNAL}";
            GF_SERVER_ROOT_URL = "%(protocol)s://%(domain)s:%(http_port)s/grafana/";
            GF_SERVER_ENABLE_GZIP = "true";

            GF_SECURITY_ADMIN_USER = "$__env{USERNAME}";
            GF_SECURITY_ADMIN_PASSWORD = "$__env{PASSWORD}";

            GF_USERS_DEFAULT_THEME = "light";

            GF_EXTERNAL_IMAGE_STORAGE_PROVIDER = "s3";
            GF_EXTERNAL_IMAGE_STORAGE_S3_ENDPOINT = "http://${IP_ADDRESS}:9000";
            GF_EXTERNAL_IMAGE_STORAGE_S3_PATH_STYLE_ACCESS = "true";
            GF_EXTERNAL_IMAGE_STORAGE_S3_BUCKET = "${MINIO_BUCKET}";
            GF_EXTERNAL_IMAGE_STORAGE_S3_REGION = config.virtualisation.oci-containers.containers.minio.environment.MINIO_REGION;
            GF_EXTERNAL_IMAGE_STORAGE_S3_ACCESS_KEY = "$__env{MINIO_SERVICE_ACCOUNT_ACCESS_KEY}";
            GF_EXTERNAL_IMAGE_STORAGE_S3_SECRET_KEY = "$__env{MINIO_SERVICE_ACCOUNT_SECRET_KEY}";

            GF_INSTALL_PLUGINS = ''
              grafana-github-datasource,
              redis-datasource,
              redis-app
            '';
          };
          extraOptions = [
            "--cpus=0.5"
            "--memory-reservation=1946m"
            "--memory=2048m"
          ];
          image = (import ./variables.nix).docker_image_grafana;
        };
      };
    };
  };

  services = {
    nginx = {
      upstreams."grafana" = {
        servers = { "127.0.0.1:3000" = {}; };
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
      after = [ "${CONTAINERS_BACKEND}-grafana.service" ];
      preStart = "${pkgs.coreutils}/bin/sleep $((RANDOM % 33))";
      serviceConfig = {
        Type = "oneshot";
        EnvironmentFile = [
          config.sops.secrets."1password/application/envs".path
          config.sops.secrets."grafana/application/envs".path
          config.sops.secrets."grafana/github/envs".path
          config.sops.secrets."grafana/minio/envs".path
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
            GitHub.'Personal access tokens (classic)'[password]=$GITHUB_TOKEN \
            MinIO.'Access Key'[text]=$MINIO_SERVICE_ACCOUNT_ACCESS_KEY \
            MinIO.'Secret Key'[password]=$MINIO_SERVICE_ACCOUNT_SECRET_KEY \
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
            GitHub.'Personal access tokens (classic)'[password]=$GITHUB_TOKEN \
            MinIO.'Access Key'[text]=$MINIO_SERVICE_ACCOUNT_ACCESS_KEY \
            MinIO.'Secret Key'[password]=$MINIO_SERVICE_ACCOUNT_SECRET_KEY \
            Postgres.'Connection command to Mattermost database'[password]="PGPASSWORD='$POSTGRESQL_PASSWORD' psql -h ${IP_ADDRESS} -p ${toString config.services.postgresql.port} -U $POSTGRESQL_USERNAME $POSTGRESQL_DATABASE_MATTERMOST" \
            Postgres.'Connection command to GitLab database'[password]="PGPASSWORD='$POSTGRESQL_PASSWORD' psql -h ${IP_ADDRESS} -p ${toString config.services.postgresql.port} -U $POSTGRESQL_USERNAME $POSTGRESQL_DATABASE_GITLAB" \
            Redis.'Connection command'[password]="sudo docker exec -ti redis redis-cli -u 'redis://$REDIS_USERNAME:$REDIS_PASSWORD_1PASSWORD@127.0.0.1:6379'" \
            --session $SESSION_TOKEN > /dev/null
          ${pkgs.coreutils}/bin/echo "Item updated successfully."
        fi
      '';
      wantedBy = [ "${CONTAINERS_BACKEND}-grafana.service" ];
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
                targets = [ "127.0.0.1:3000" ];
              }];
              metrics_path = "/metrics";
            }];
            remote_write = [{
              url = "http://${IP_ADDRESS}:9009/mimir/api/v1/push";
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
                  systemd_job = "systemd-journal";
                };
                path = "/var/log/journal";
              };
              relabel_configs = [
                {
                  source_labels = [ "__journal__systemd_unit" ];
                  regex = "(grafana-minio|grafana-postgres|grafana-redis|${CONTAINERS_BACKEND}-grafana|grafana-1password).service";
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
