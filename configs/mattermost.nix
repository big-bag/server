{ config, pkgs, lib, ... }:

let
  CONTAINERS_BACKEND = config.virtualisation.oci-containers.backend;
  IP_ADDRESS = (import ./connection-parameters.nix).ip_address;
  MINIO_BUCKET = "mattermost";
  DOMAIN_NAME_INTERNAL = (import ./connection-parameters.nix).domain_name_internal;
in

{
  systemd.services = {
    mattermost-prepare = {
      before = [ "${CONTAINERS_BACKEND}-mattermost.service" ];
      serviceConfig = {
        Type = "oneshot";
      };
      script = ''
        ${pkgs.coreutils}/bin/mkdir -p /mnt/ssd/services/mattermost/{config,logs,bleve-indexes,plugins,client/plugins}
        ${pkgs.coreutils}/bin/chown -R 2000:2000 /mnt/ssd/services/mattermost
      '';
      wantedBy = [ "${CONTAINERS_BACKEND}-mattermost.service" ];
    };
  };

  sops.secrets = {
    "mattermost/postgres/envs" = {
      mode = "0400";
      owner = config.users.users.root.name;
      group = config.users.users.root.group;
    };
  };

  systemd.services = {
    mattermost-postgres = {
      after = [ "postgresql.service" ];
      before = [ "${CONTAINERS_BACKEND}-mattermost.service" ];
      serviceConfig = {
        Type = "oneshot";
        EnvironmentFile = config.sops.secrets."mattermost/postgres/envs".path;
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
                      ENCRYPTED PASSWORD '$POSTGRESQL_PASSWORD_DATABASE';
                  RAISE NOTICE 'Role "$POSTGRESQL_USERNAME" created successfully.';
              ELSE
                  ALTER ROLE $POSTGRESQL_USERNAME WITH
                      LOGIN
                      NOINHERIT
                      CONNECTION LIMIT -1
                      ENCRYPTED PASSWORD '$POSTGRESQL_PASSWORD_DATABASE';
                  RAISE NOTICE 'Role "$POSTGRESQL_USERNAME" updated successfully.';
              END IF;
          END
          \$$;

          SELECT 'CREATE DATABASE $POSTGRESQL_DATABASE OWNER $POSTGRESQL_USERNAME'
              WHERE NOT EXISTS (
                  SELECT FROM pg_database
                  WHERE datname = '$POSTGRESQL_DATABASE'
              );
          \gexec

          REVOKE CONNECT
              ON DATABASE $POSTGRESQL_DATABASE
              FROM PUBLIC;

          \connect $POSTGRESQL_DATABASE

          REVOKE ALL PRIVILEGES
              ON SCHEMA public
              FROM PUBLIC;
          REVOKE ALL PRIVILEGES
              ON ALL TABLES IN SCHEMA public
              FROM PUBLIC;

          GRANT USAGE, CREATE
              ON SCHEMA public
              TO $POSTGRESQL_USERNAME;
          GRANT SELECT, INSERT, UPDATE, DELETE
              ON ALL TABLES IN SCHEMA public
              TO $POSTGRESQL_USERNAME;
        EOSQL
      '';
      wantedBy = [
        "postgresql.service"
        "${CONTAINERS_BACKEND}-mattermost.service"
      ];
    };
  };

  sops.secrets = {
    "minio/application/envs" = {
      mode = "0400";
      owner = config.users.users.root.name;
      group = config.users.users.root.group;
    };
  };

  sops.secrets = {
    "mattermost/minio/envs" = {
      mode = "0400";
      owner = config.users.users.root.name;
      group = config.users.users.root.group;
    };
  };

  systemd.services = {
    mattermost-minio = {
      before = [ "${CONTAINERS_BACKEND}-mattermost.service" ];
      serviceConfig = {
        Type = "oneshot";
        EnvironmentFile = [
          config.sops.secrets."minio/application/envs".path
          config.sops.secrets."mattermost/minio/envs".path
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
                        "Action": "s3:ListBucket",
                        "Resource": "arn:aws:s3:::${MINIO_BUCKET}"
                    },
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
                --comment mattermost \
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
      wantedBy = [ "${CONTAINERS_BACKEND}-mattermost.service" ];
    };
  };

  virtualisation = {
    oci-containers = {
      containers = {
        mattermost = {
          autoStart = true;
          ports = [ "${IP_ADDRESS}:8065:8065" ];
          volumes = let
            entrypoint = pkgs.writeTextFile {
              name = "entrypoint.sh";
              text = ''
                #!/bin/bash

                export MM_SQLSETTINGS_DATASOURCE="postgres://$POSTGRESQL_USERNAME:$POSTGRESQL_PASSWORD_APPLICATION@${IP_ADDRESS}:${toString config.services.postgresql.port}/$POSTGRESQL_DATABASE?sslmode=disable&connect_timeout=10&binary_parameters=yes"
                export MM_FILESETTINGS_AMAZONS3ACCESSKEYID=$MINIO_SERVICE_ACCOUNT_ACCESS_KEY
                export MM_FILESETTINGS_AMAZONS3SECRETACCESSKEY=$MINIO_SERVICE_ACCOUNT_SECRET_KEY

                if [ "''${1:0:1}" = '-' ]; then
                    set -- mattermost "$@"
                fi

                exec "$@"
              '';
              executable = true;
            };
          in [
            "${entrypoint}:/entrypoint.sh:ro"
            "/mnt/ssd/services/mattermost/config:/mattermost/config:rw"
            "/mnt/ssd/services/mattermost/logs:/mattermost/logs:rw"
            "/mnt/ssd/services/mattermost/bleve-indexes:/mattermost/bleve-indexes:rw"
            "/mnt/ssd/services/mattermost/plugins:/mattermost/plugins:rw"
            "/mnt/ssd/services/mattermost/client/plugins:/mattermost/client/plugins:rw"
          ];
          environmentFiles = [
            config.sops.secrets."mattermost/postgres/envs".path
            config.sops.secrets."mattermost/minio/envs".path
          ];
          environment = {
            TZ = "Europe/Moscow";

            MM_SERVICESETTINGS_SITEURL = "https://${DOMAIN_NAME_INTERNAL}/mattermost";
            MM_SERVICESETTINGS_LISTENADDRESS = ":8065";
            MM_SERVICESETTINGS_ALLOWEDUNTRUSTEDINTERNALCONNECTIONS = "${IP_ADDRESS}";
            MM_SERVICESETTINGS_ALLOWCORSFROM = "*";
            MM_SERVICESETTINGS_ENABLELOCALMODE = "true";

            MM_PASSWORDSETTINGS_MINIMUMLENGTH = "10";
            MM_PASSWORDSETTINGS_LOWERCASE = "true";
            MM_PASSWORDSETTINGS_NUMBER = "true";
            MM_PASSWORDSETTINGS_UPPERCASE = "true";
            MM_PASSWORDSETTINGS_SYMBOL = "true";

            MM_FILESETTINGS_MAXFILESIZE = "52428800";
            MM_FILESETTINGS_DRIVERNAME = "amazons3";
            MM_FILESETTINGS_AMAZONS3BUCKET = "${MINIO_BUCKET}";
            MM_FILESETTINGS_AMAZONS3ENDPOINT = "${IP_ADDRESS}:9000";
            MM_FILESETTINGS_AMAZONS3SSL = "false";

            MM_BLEVESETTINGS_INDEXDIR = "./bleve-indexes";

            MM_PLUGINSETTINGS_DIRECTORY = "./plugins";
            MM_PLUGINSETTINGS_CLIENTDIRECTORY = "./client/plugins";
          };
          extraOptions = [
            "--security-opt=no-new-privileges=true"
            "--pids-limit=200"
            "--tmpfs=/tmp"
            "--cpus=0.0625"
            "--memory-reservation=243m"
            "--memory=256m"
          ];
          image = (import ./variables.nix).docker_image_mattermost;
        };
      };
    };
  };

  networking = {
    firewall = {
      allowedTCPPorts = [ 8065 ];
    };
  };

  sops.secrets = {
    "mattermost/application/envs" = {
      mode = "0400";
      owner = config.users.users.root.name;
      group = config.users.users.root.group;
    };
  };

  systemd.services = {
    mattermost-configure = {
      after = [ "${CONTAINERS_BACKEND}-mattermost.service" ];
      serviceConfig = {
        Type = "oneshot";
        EnvironmentFile = config.sops.secrets."mattermost/application/envs".path;
      };
      script = ''
        while ! ${pkgs.curl}/bin/curl --silent --request GET http://${IP_ADDRESS}:8065/mattermost/api/v4/system/ping |
          ${pkgs.gnugrep}/bin/grep OK
        do
          ${pkgs.coreutils}/bin/echo "Waiting for Mattermost availability."
          ${pkgs.coreutils}/bin/sleep 1
        done

        case `
          ${pkgs.${CONTAINERS_BACKEND}}/bin/${CONTAINERS_BACKEND} exec mattermost mmctl user list \
            --local |
          ${pkgs.gnugrep}/bin/grep $MATTERMOST_USERNAME > /dev/null
          ${pkgs.coreutils}/bin/echo $?
        ` in
          "1" )
            ${pkgs.${CONTAINERS_BACKEND}}/bin/${CONTAINERS_BACKEND} exec mattermost mmctl user create \
              --email $MATTERMOST_USERNAME@${DOMAIN_NAME_INTERNAL} \
              --username $MATTERMOST_USERNAME \
              --password "$MATTERMOST_PASSWORD" \
              --local
          ;;
          "0" )
            ${pkgs.${CONTAINERS_BACKEND}}/bin/${CONTAINERS_BACKEND} exec mattermost mmctl user email \
              $MATTERMOST_USERNAME \
              $MATTERMOST_USERNAME@${DOMAIN_NAME_INTERNAL} \
              --local
            ${pkgs.${CONTAINERS_BACKEND}}/bin/${CONTAINERS_BACKEND} exec mattermost mmctl user change-password \
              $MATTERMOST_USERNAME \
              --password "$MATTERMOST_PASSWORD" \
              --local
          ;;
        esac

        export TEAM=${lib.strings.stringAsChars (x: if x == "." then "-" else x) DOMAIN_NAME_INTERNAL}
        export TEAM_NAME=$(
          ${pkgs.coreutils}/bin/echo ${DOMAIN_NAME_INTERNAL} |
          ${pkgs.gnused}/bin/sed 's/\./ /g' |
          ${pkgs.gawk}/bin/awk '{for(i=1;i<=NF;i++){ $i=toupper(substr($i,1,1)) substr($i,2) }}1'
        )

        case `
          ${pkgs.${CONTAINERS_BACKEND}}/bin/${CONTAINERS_BACKEND} exec mattermost mmctl team list \
            --local |
          ${pkgs.gnugrep}/bin/grep $TEAM > /dev/null
          ${pkgs.coreutils}/bin/echo $?
        ` in
          "1" )
            ${pkgs.${CONTAINERS_BACKEND}}/bin/${CONTAINERS_BACKEND} exec mattermost mmctl team create \
              --name $TEAM \
              --display-name "$TEAM_NAME" \
              --private \
              --local
          ;;
          "0" )
            ${pkgs.${CONTAINERS_BACKEND}}/bin/${CONTAINERS_BACKEND} exec mattermost mmctl team rename \
              $TEAM \
              --display-name "$TEAM_NAME" \
              --local
            ${pkgs.${CONTAINERS_BACKEND}}/bin/${CONTAINERS_BACKEND} exec mattermost mmctl team modify \
              $TEAM \
              --private \
              --local
          ;;
        esac

        ${pkgs.${CONTAINERS_BACKEND}}/bin/${CONTAINERS_BACKEND} exec mattermost mmctl team users add \
          $TEAM \
          $MATTERMOST_USERNAME@${DOMAIN_NAME_INTERNAL} \
          --local
      '';
      wantedBy = [ "${CONTAINERS_BACKEND}-mattermost.service" ];
    };
  };

  services = {
    nginx = {
      proxyCachePath = {
        mattermost = {
          enable = true;
          levels = "1:2";
          useTempPath = false;
          keysZoneName = "mattermost_cache";
          keysZoneSize = "10m";
          inactive = "120m";
          maxSize = "3g";
        };
      };

      upstreams."mattermost" = {
        servers = let
          MATTERMOST_ADDRESS = "${IP_ADDRESS}:8065";
        in { "${MATTERMOST_ADDRESS}" = {}; };
        extraConfig = "keepalive 64;";
      };

      virtualHosts.${DOMAIN_NAME_INTERNAL} = let
        CONFIG_LOCATION = ''
          client_max_body_size 50M;

          # gzip for performance
          gzip on;
          gzip_comp_level 6;
          gzip_proxied any;
          gzip_types text/plain text/css text/xml application/json application/javascript application/rss+xml application/atom+xml image/svg+xml;
          gzip_vary on;

          # security headers
          add_header X-Frame-Options "SAMEORIGIN" always;
          add_header X-XSS-Protection "1; mode=block" always;
          add_header X-Content-Type-Options "nosniff" always;
          add_header Referrer-Policy no-referrer;
          add_header Strict-Transport-Security "max-age=63072000" always;
          add_header Permissions-Policy "interest-cohort=()";

          proxy_set_header Host $host;
          proxy_set_header X-Real-IP $remote_addr;
          proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
          proxy_set_header X-Forwarded-Proto $scheme;
          proxy_set_header X-Frame-Options SAMEORIGIN;
          proxy_set_header Early-Data $ssl_early_data;

          proxy_buffers 256 16k;
          proxy_buffer_size 16k;

          proxy_http_version 1.1;
        '';
      in {
        locations."~ /mattermost/api/v[0-9]+/(users/)?websocket$" = {
          extraConfig = ''
            ${CONFIG_LOCATION}
            client_body_timeout 60;

            proxy_set_header Upgrade $http_upgrade;
            proxy_set_header Connection "upgrade";

            send_timeout 300;
            lingering_timeout 5;

            proxy_connect_timeout 90;
            proxy_send_timeout 300;
            proxy_read_timeout 90s;
          '';

          proxyPass = "http://mattermost";
        };

        locations."/mattermost" = {
          extraConfig = ''
            ${CONFIG_LOCATION}
            proxy_set_header Connection "";

            proxy_read_timeout 600s;

            proxy_cache mattermost_cache;
            proxy_cache_revalidate on;
            proxy_cache_min_uses 2;
            proxy_cache_use_stale timeout;
            proxy_cache_lock on;
          '';

          proxyPass = "http://mattermost";
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
    mattermost-1password = {
      after = [
        "${CONTAINERS_BACKEND}-mattermost.service"
        "mattermost-configure.service"
      ];
      preStart = "${pkgs.coreutils}/bin/sleep $((RANDOM % 33))";
      serviceConfig = {
        Type = "oneshot";
        EnvironmentFile = [
          config.sops.secrets."1password/application/envs".path
          config.sops.secrets."mattermost/application/envs".path
          config.sops.secrets."mattermost/postgres/envs".path
          config.sops.secrets."mattermost/minio/envs".path
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

        ${pkgs._1password}/bin/op item get Mattermost \
          --vault Server \
          --session $SESSION_TOKEN > /dev/null

        if [ $? != 0 ]
        then
          ${pkgs._1password}/bin/op item template get Login --session $SESSION_TOKEN | ${pkgs._1password}/bin/op item create --vault Server - \
            --title Mattermost \
            --url https://${DOMAIN_NAME_INTERNAL}/mattermost \
            username=$MATTERMOST_USERNAME@${DOMAIN_NAME_INTERNAL} \
            password=$MATTERMOST_PASSWORD \
            Postgres.'Connection command'[password]="PGPASSWORD='$POSTGRESQL_PASSWORD_DATABASE' psql -h ${IP_ADDRESS} -p ${toString config.services.postgresql.port} -U $POSTGRESQL_USERNAME $POSTGRESQL_DATABASE" \
            MinIO.'Access Key'[text]=$MINIO_SERVICE_ACCOUNT_ACCESS_KEY \
            MinIO.'Secret Key'[password]=$MINIO_SERVICE_ACCOUNT_SECRET_KEY \
            --session $SESSION_TOKEN > /dev/null
          ${pkgs.coreutils}/bin/echo "Item created successfully."
        else
          ${pkgs._1password}/bin/op item edit Mattermost \
            --vault Server \
            --url https://${DOMAIN_NAME_INTERNAL}/mattermost \
            username=$MATTERMOST_USERNAME@${DOMAIN_NAME_INTERNAL} \
            password=$MATTERMOST_PASSWORD \
            Postgres.'Connection command'[password]="PGPASSWORD='$POSTGRESQL_PASSWORD_DATABASE' psql -h ${IP_ADDRESS} -p ${toString config.services.postgresql.port} -U $POSTGRESQL_USERNAME $POSTGRESQL_DATABASE" \
            MinIO.'Access Key'[text]=$MINIO_SERVICE_ACCOUNT_ACCESS_KEY \
            MinIO.'Secret Key'[password]=$MINIO_SERVICE_ACCOUNT_SECRET_KEY \
            --session $SESSION_TOKEN > /dev/null
          ${pkgs.coreutils}/bin/echo "Item updated successfully."
        fi
      '';
      wantedBy = [
        "${CONTAINERS_BACKEND}-mattermost.service"
        "mattermost-configure.service"
      ];
    };
  };

  services = {
    grafana-agent = {
      settings = {
        logs = {
          configs = [{
            name = "mattermost";
            clients = [{
              url = "http://${config.services.loki.configuration.server.http_listen_address}:${toString config.services.loki.configuration.server.http_listen_port}/loki/api/v1/push";
            }];
            positions = {
              filename = "/var/lib/private/grafana-agent/positions/mattermost.yml";
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
                  regex = "(mattermost-prepare|mattermost-postgres|mattermost-minio|${CONTAINERS_BACKEND}-mattermost|mattermost-configure|mattermost-1password).service";
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
