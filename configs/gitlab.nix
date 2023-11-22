{ config, pkgs, lib, ... }:

let
  CONTAINERS_BACKEND = config.virtualisation.oci-containers.backend;
  IP_ADDRESS = (import ./connection-parameters.nix).ip_address;
  DOMAIN_NAME_INTERNAL = (import ./connection-parameters.nix).domain_name_internal;
in

{
  systemd.services = {
    gitlab-prepare = {
      before = [ "${CONTAINERS_BACKEND}-gitlab.service" ];
      serviceConfig = {
        Type = "oneshot";
      };
      script = ''
        ${pkgs.coreutils}/bin/mkdir -p /mnt/ssd/services/gitlab/{config,logs,data}
        ${pkgs.coreutils}/bin/chmod 0775 /mnt/ssd/services/gitlab/config
      '';
      wantedBy = [ "${CONTAINERS_BACKEND}-gitlab.service" ];
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
    "gitlab/minio/envs" = {
      mode = "0400";
      owner = config.users.users.root.name;
      group = config.users.users.root.group;
    };
  };

  systemd.services = {
    gitlab-minio = {
      before = [ "${CONTAINERS_BACKEND}-gitlab.service" ];
      serviceConfig = {
        Type = "oneshot";
        EnvironmentFile = [
          config.sops.secrets."minio/application/envs".path
          config.sops.secrets."gitlab/minio/envs".path
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
                        "Resource": [
                            "arn:aws:s3:::gitlab-artifacts/*",
                            "arn:aws:s3:::gitlab-external-diffs/*",
                            "arn:aws:s3:::gitlab-lfs/*",
                            "arn:aws:s3:::gitlab-uploads/*",
                            "arn:aws:s3:::gitlab-packages/*",
                            "arn:aws:s3:::gitlab-dependency-proxy/*",
                            "arn:aws:s3:::gitlab-terraform-state/*",
                            "arn:aws:s3:::gitlab-ci-secure-files/*",
                            "arn:aws:s3:::gitlab-pages/*",
                            "arn:aws:s3:::gitlab-backup/*",
                            "arn:aws:s3:::gitlab-registry/*"
                        ]
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

            ${pkgs.minio-client}/bin/mc mb --ignore-existing $ALIAS/gitlab-artifacts
            ${pkgs.minio-client}/bin/mc mb --ignore-existing $ALIAS/gitlab-external-diffs
            ${pkgs.minio-client}/bin/mc mb --ignore-existing $ALIAS/gitlab-lfs
            ${pkgs.minio-client}/bin/mc mb --ignore-existing $ALIAS/gitlab-uploads
            ${pkgs.minio-client}/bin/mc mb --ignore-existing $ALIAS/gitlab-packages
            ${pkgs.minio-client}/bin/mc mb --ignore-existing $ALIAS/gitlab-dependency-proxy
            ${pkgs.minio-client}/bin/mc mb --ignore-existing $ALIAS/gitlab-terraform-state
            ${pkgs.minio-client}/bin/mc mb --ignore-existing $ALIAS/gitlab-ci-secure-files
            ${pkgs.minio-client}/bin/mc mb --ignore-existing $ALIAS/gitlab-pages
            ${pkgs.minio-client}/bin/mc mb --ignore-existing $ALIAS/gitlab-backup
            ${pkgs.minio-client}/bin/mc mb --ignore-existing $ALIAS/gitlab-registry

            ${pkgs.minio-client}/bin/mc admin user svcacct info $ALIAS $MINIO_SERVICE_ACCOUNT_ACCESS_KEY

            if [ $? != 0 ]
            then
              ${pkgs.minio-client}/bin/mc admin user svcacct add \
                --access-key $MINIO_SERVICE_ACCOUNT_ACCESS_KEY \
                --secret-key $MINIO_SERVICE_ACCOUNT_SECRET_KEY \
                --policy ${policy_json} \
                --comment gitlab \
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
      wantedBy = [ "${CONTAINERS_BACKEND}-gitlab.service" ];
    };
  };

  sops.secrets = {
    "gitlab/postgres/envs" = {
      mode = "0400";
      owner = config.users.users.root.name;
      group = config.users.users.root.group;
    };
  };

  systemd.services = {
    gitlab-postgres = {
      after = [ "postgresql.service" ];
      before = [ "${CONTAINERS_BACKEND}-gitlab.service" ];
      serviceConfig = {
        Type = "oneshot";
        EnvironmentFile = config.sops.secrets."gitlab/postgres/envs".path;
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

          CREATE EXTENSION IF NOT EXISTS pg_trgm;
          CREATE EXTENSION IF NOT EXISTS btree_gist;

          SELECT format('
              REVOKE ALL PRIVILEGES
                  ON SCHEMA %I
                  FROM PUBLIC
              ', schema_name)
              FROM information_schema.schemata
              WHERE schema_name <> 'pg_toast'
                  AND schema_name <> 'pg_catalog'
                  AND schema_name <> 'information_schema';
          SELECT format('
              REVOKE ALL PRIVILEGES
                  ON ALL TABLES IN SCHEMA %I
                  FROM PUBLIC
              ', schema_name)
              FROM information_schema.schemata
              WHERE schema_name <> 'pg_toast'
                  AND schema_name <> 'pg_catalog'
                  AND schema_name <> 'information_schema';

          ALTER SCHEMA public OWNER TO $POSTGRESQL_USERNAME;

          SELECT format('
              GRANT USAGE, CREATE
                  ON SCHEMA %I
                  TO $POSTGRESQL_USERNAME
              ', schema_name)
              FROM information_schema.schemata
              WHERE schema_name <> 'pg_toast'
                  AND schema_name <> 'pg_catalog'
                  AND schema_name <> 'information_schema';
          SELECT format('
              GRANT SELECT, INSERT, UPDATE, DELETE
                  ON ALL TABLES IN SCHEMA %I
                  TO $POSTGRESQL_USERNAME
              ', schema_name)
              FROM information_schema.schemata
              WHERE schema_name <> 'pg_toast'
                  AND schema_name <> 'pg_catalog'
                  AND schema_name <> 'information_schema';
        EOSQL
      '';
      wantedBy = [
        "postgresql.service"
        "${CONTAINERS_BACKEND}-gitlab.service"
      ];
    };
  };

  sops.secrets = {
    "gitlab/minio/file/access_key" = {
      mode = "0400";
      owner = config.users.users.root.name;
      group = config.users.users.root.group;
    };
  };

  sops.secrets = {
    "gitlab/minio/file/secret_key" = {
      mode = "0400";
      owner = config.users.users.root.name;
      group = config.users.users.root.group;
    };
  };

  sops.secrets = {
    "gitlab/application/file/password" = {
      mode = "0400";
      owner = config.users.users.root.name;
      group = config.users.users.root.group;
    };
  };

  sops.secrets = {
    "gitlab/application/file/token" = {
      mode = "0400";
      owner = config.users.users.root.name;
      group = config.users.users.root.group;
    };
  };

  sops.secrets = {
    "gitlab/postgres/file/database" = {
      mode = "0400";
      owner = config.users.users.root.name;
      group = config.users.users.root.group;
    };
  };

  sops.secrets = {
    "gitlab/postgres/file/username" = {
      mode = "0400";
      owner = config.users.users.root.name;
      group = config.users.users.root.group;
    };
  };

  sops.secrets = {
    "gitlab/postgres/file/password" = {
      mode = "0400";
      owner = config.users.users.root.name;
      group = config.users.users.root.group;
    };
  };

  sops.secrets = {
    "redis/application/file/password" = {
      mode = "0400";
      owner = config.users.users.root.name;
      group = config.users.users.root.group;
    };
  };

  virtualisation = {
    oci-containers = {
      containers = {
        gitlab = {
          autoStart = true;
          ports = [
            "${IP_ADDRESS}:8181:8181"
            "127.0.0.1:5000:5000"
            "127.0.0.1:8090:8090"
            "127.0.0.1:5001:5001"
            "127.0.0.1:9229:9229"
            "127.0.0.1:8083:8083"
            "127.0.0.1:8082:8082"
            "127.0.0.1:9235:9235"
            "127.0.0.1:9168:9168"
            "127.0.0.1:9236:9236"
          ];
          volumes = [
            "/mnt/ssd/services/gitlab/config:/etc/gitlab:rw"
            "/mnt/ssd/services/gitlab/logs:/var/log/gitlab:rw"
            "/mnt/ssd/services/gitlab/data:/var/opt/gitlab:rw"
            "${config.sops.secrets."gitlab/minio/file/access_key".path}:/run/secrets/minio_access_key:ro"
            "${config.sops.secrets."gitlab/minio/file/secret_key".path}:/run/secrets/minio_secret_key:ro"
            "${config.sops.secrets."gitlab/application/file/password".path}:/run/secrets/gitlab_password:ro"
            "${config.sops.secrets."gitlab/application/file/token".path}:/run/secrets/gitlab_token:ro"
            "${config.sops.secrets."gitlab/postgres/file/database".path}:/run/secrets/postgres_database:ro"
            "${config.sops.secrets."gitlab/postgres/file/username".path}:/run/secrets/postgres_username:ro"
            "${config.sops.secrets."gitlab/postgres/file/password".path}:/run/secrets/postgres_password:ro"
            "${config.sops.secrets."redis/application/file/password".path}:/run/secrets/redis_password:ro"
          ];
          environment = let
            MINIO_REGION = config.virtualisation.oci-containers.containers.minio.environment.MINIO_REGION;
          in {
            GITLAB_OMNIBUS_CONFIG = ''
              ## GitLab URL
              ##! URL on which GitLab will be reachable.
              ##! For more details on configuring external_url see:
              ##! https://docs.gitlab.com/omnibus/settings/configuration.html#configuring-the-external-url-for-gitlab
              ##!
              ##! Note: During installation/upgrades, the value of the environment variable
              ##! EXTERNAL_URL will be used to populate/replace this value.
              ##! On AWS EC2 instances, we also attempt to fetch the public hostname/IP
              ##! address from AWS. For more details, see:
              ##! https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/instancedata-data-retrieval.html
              external_url 'https://gitlab.${DOMAIN_NAME_INTERNAL}'

              ################################################################################
              ## gitlab.yml configuration
              ##! Docs: https://gitlab.com/gitlab-org/omnibus-gitlab/blob/master/doc/settings/gitlab.yml.md
              ################################################################################

              ### GitLab email server settings
              ###! Docs: https://docs.gitlab.com/omnibus/settings/smtp.html
              ###! **Use smtp instead of sendmail/postfix.**
              gitlab_rails['smtp_enable'] = false

              ### Email Settings
              gitlab_rails['gitlab_email_enabled'] = false

              ### Monitoring settings
              ###! IP whitelist controlling access to monitoring endpoints
              gitlab_rails['monitoring_whitelist'] = ['0.0.0.0/0']

              ### Consolidated (simplified) object storage configuration
              ###! This uses a single credential for object storage with multiple buckets.
              ###! It also enables Workhorse to upload files directly with its own S3 client
              ###! instead of using pre-signed URLs.
              ###!
              ###! This configuration will only take effect if the object_store
              ###! sections are not defined within the types. For example, enabling
              ###! gitlab_rails['artifacts_object_store_enabled'] or
              ###! gitlab_rails['lfs_object_store_enabled'] will prevent the
              ###! consolidated settings from being used.
              ###!
              ###! Be sure to use different buckets for each type of object.
              ###! Docs: https://docs.gitlab.com/ee/administration/object_storage.html
              gitlab_rails['object_store']['enabled'] = true
              gitlab_rails['object_store']['connection'] = {
                'provider' => 'AWS',
                'endpoint' => 'http://${IP_ADDRESS}:9000',
                'region' => '${MINIO_REGION}',
                'path_style' => 'true',
                'aws_access_key_id' => File.read('/run/secrets/minio_access_key').gsub("\n", ""),
                'aws_secret_access_key' => File.read('/run/secrets/minio_secret_key').gsub("\n", "")
              }
              gitlab_rails['object_store']['proxy_download'] = true
              gitlab_rails['object_store']['objects']['artifacts']['bucket'] = 'gitlab-artifacts'
              gitlab_rails['object_store']['objects']['external_diffs']['bucket'] = 'gitlab-external-diffs'
              gitlab_rails['object_store']['objects']['lfs']['bucket'] = 'gitlab-lfs'
              gitlab_rails['object_store']['objects']['uploads']['bucket'] = 'gitlab-uploads'
              gitlab_rails['object_store']['objects']['packages']['bucket'] = 'gitlab-packages'
              gitlab_rails['object_store']['objects']['dependency_proxy']['bucket'] = 'gitlab-dependency-proxy'
              gitlab_rails['object_store']['objects']['terraform_state']['bucket'] = 'gitlab-terraform-state'
              gitlab_rails['object_store']['objects']['ci_secure_files']['bucket'] = 'gitlab-ci-secure-files'
              gitlab_rails['object_store']['objects']['pages']['bucket'] = 'gitlab-pages'

              ### Backup Settings
              ###! Docs: https://docs.gitlab.com/omnibus/settings/backups.html
              gitlab_rails['backup_upload_connection'] = {
                'provider' => 'AWS',
                'endpoint' => 'http://${IP_ADDRESS}:9000',
                'region' => '${MINIO_REGION}',
                'path_style' => 'true',
                'aws_access_key_id' => File.read('/run/secrets/minio_access_key').gsub("\n", ""),
                'aws_secret_access_key' => File.read('/run/secrets/minio_secret_key').gsub("\n", "")
              }
              gitlab_rails['backup_upload_remote_directory'] = 'gitlab-backup'

              #### Change the initial default admin password and shared runner registration tokens.
              ####! **Only applicable on initial setup, changing these settings after database
              ####!   is created and seeded won't yield any change.**
              gitlab_rails['initial_root_password'] = File.read('/run/secrets/gitlab_password').gsub("\n", "")
              gitlab_rails['initial_shared_runners_registration_token'] = File.read('/run/secrets/gitlab_token').gsub("\n", "")

              #### Toggle if initial root password should be written to /etc/gitlab/initial_root_password
              gitlab_rails['store_initial_root_password'] = false

              ### GitLab database settings
              ###! Docs: https://docs.gitlab.com/omnibus/settings/database.html
              ###! **Only needed if you use an external database.**
              gitlab_rails['db_database'] = File.read('/run/secrets/postgres_database').gsub("\n", "")
              gitlab_rails['db_username'] = File.read('/run/secrets/postgres_username').gsub("\n", "")
              gitlab_rails['db_password'] = File.read('/run/secrets/postgres_password').gsub("\n", "")
              gitlab_rails['db_host'] = '${IP_ADDRESS}'
              gitlab_rails['db_port'] = ${toString config.services.postgresql.port}

              ### GitLab Redis settings
              ###! Connect to your own Redis instance
              ###! Docs: https://docs.gitlab.com/omnibus/settings/redis.html

              #### Redis TCP connection
              gitlab_rails['redis_host'] = '${IP_ADDRESS}'
              gitlab_rails['redis_port'] = 6379
              gitlab_rails['redis_password'] = File.read('/run/secrets/redis_password').gsub("\n", "")

              ################################################################################
              ## Container Registry settings
              ##! Docs: https://docs.gitlab.com/ee/administration/packages/container_registry.html
              ################################################################################

              registry_external_url 'https://registry.${DOMAIN_NAME_INTERNAL}'

              ### Settings used by Registry application
              registry['registry_http_addr'] = '0.0.0.0:5000'
              registry['debug_addr'] = '0.0.0.0:5001'

              ### Registry backend storage
              ###! Docs: https://docs.gitlab.com/ee/administration/packages/container_registry.html#configure-storage-for-the-container-registry
              registry['storage'] = {
                's3' => {
                  'provider' => 'AWS',
                  'regionendpoint' => 'http://${IP_ADDRESS}:9000',
                  'region' => '${MINIO_REGION}',
                  'path_style' => 'true',
                  'accesskey' => File.read('/run/secrets/minio_access_key').gsub("\n", ""),
                  'secretkey' => File.read('/run/secrets/minio_secret_key').gsub("\n", ""),
                  'bucket' => 'gitlab-registry'
                }
              }

              ################################################################################
              ## GitLab Workhorse
              ##! Docs: https://gitlab.com/gitlab-org/gitlab/-/blob/master/workhorse/README.md
              ################################################################################

              gitlab_workhorse['listen_network'] = 'tcp'
              gitlab_workhorse['listen_addr'] = '0.0.0.0:8181'

              gitlab_workhorse['prometheus_listen_addr'] = '0.0.0.0:9229'

              ##! Resource limitations for the dynamic image scaler.
              ##! Exceeding these thresholds will cause Workhorse to serve images in their original size.
              ##!
              ##! Maximum number of scaler processes that are allowed to execute concurrently.
              ##! It is recommended for this not to exceed the number of CPUs available.
              gitlab_workhorse['image_scaler_max_procs'] = 1

              ################################################################################
              ## GitLab Puma
              ##! Tweak puma settings.
              ##! Docs: https://docs.gitlab.com/ee/administration/operations/puma.html
              ################################################################################

              ### Advanced settings
              puma['listen'] = '127.0.0.1'
              puma['port'] = 8080

              puma['exporter_enabled'] = true
              puma['exporter_address'] = '0.0.0.0'
              puma['exporter_port'] = 8083

              ################################################################################
              ## GitLab Sidekiq
              ################################################################################

              ##! Specifies where Prometheus metrics endpoints should be made available for Sidekiq processes.
              sidekiq['listen_address'] = '0.0.0.0'
              sidekiq['listen_port'] = 8082

              ##! Specifies where health-check endpoints should be made available for Sidekiq processes.
              ##! Defaults to the same settings as for Prometheus metrics (see above).
              sidekiq['health_checks_listen_address'] = '127.0.0.1'
              sidekiq['health_checks_listen_port'] = 8092

              ################################################################
              ## GitLab PostgreSQL
              ################################################################

              ###! Changing any of these settings requires a restart of postgresql.
              ###! By default, reconfigure reloads postgresql if it is running. If you
              ###! change any of these settings, be sure to run `gitlab-ctl restart postgresql`
              ###! after reconfigure in order for the changes to take effect.
              postgresql['enable'] = false

              ################################################################################
              ## GitLab Redis
              ##! **Can be disabled if you are using your own Redis instance.**
              ##! Docs: https://docs.gitlab.com/omnibus/settings/redis.html
              ################################################################################

              redis['enable'] = false

              ################################################################################
              ## GitLab NGINX
              ##! Docs: https://docs.gitlab.com/omnibus/settings/nginx.html
              ################################################################################

              nginx['enable'] = false

              ################################################################################
              ## GitLab Pages
              ##! Docs: https://docs.gitlab.com/ee/administration/pages/
              ################################################################################

              ##! Define to enable GitLab Pages
              pages_external_url 'https://pages.${DOMAIN_NAME_INTERNAL}'
              gitlab_pages['enable'] = true

              ##! Configure to enable health check endpoint on GitLab Pages
              gitlab_pages['status_uri'] = '/@status'

              ##! Listen for requests forwarded by reverse proxy
              gitlab_pages['listen_proxy'] = '0.0.0.0:8090'

              ##! Prometheus metrics for Pages docs: https://gitlab.com/gitlab-org/gitlab-pages/#enable-prometheus-metrics
              gitlab_pages['metrics_address'] = '0.0.0.0:9235'

              ################################################################################
              ## GitLab Pages NGINX
              ################################################################################

              # All the settings defined in the "GitLab Nginx" section are also available in
              # this "GitLab Pages NGINX" section, using the key `pages_nginx`.  However,
              # those settings should be explicitly set. That is, settings given as
              # `nginx['some_setting']` WILL NOT be automatically replicated as
              # `pages_nginx['some_setting']` and should be set separately.

              # Below you can find settings that are exclusive to "GitLab Pages NGINX"
              pages_nginx['enable'] = false

              ################################################################################
              ## GitLab Kubernetes Agent Server
              ##! Docs: https://gitlab.com/gitlab-org/cluster-integration/gitlab-agent/blob/master/README.md
              ################################################################################

              ##! Settings used by the GitLab application
              gitlab_rails['gitlab_kas_enabled'] = false

              ##! Define to enable GitLab KAS
              gitlab_kas['enable'] = false

              ################################################################################
              ## Prometheus
              ##! Docs: https://docs.gitlab.com/ee/administration/monitoring/prometheus/
              ################################################################################

              prometheus['enable'] = false

              ################################################################################
              ###! **Only needed if Prometheus and Rails are not on the same server.**
              ### For example, in a multi-node architecture, Prometheus will be installed on the monitoring node, while Rails will be on the Rails node.
              ### https://docs.gitlab.com/ee/administration/monitoring/prometheus/index.html#using-an-external-prometheus-server
              ### This value should be the address at which Prometheus is available to a GitLab Rails(Puma, Sidekiq) node.
              ################################################################################
              gitlab_rails['prometheus_address'] = '${config.services.prometheus.listenAddress}:${toString config.services.prometheus.port}'

              ################################################################################
              ## Prometheus Alertmanager
              ################################################################################

              alertmanager['enable'] = false

              ################################################################################
              ## Prometheus Node Exporter
              ##! Docs: https://docs.gitlab.com/ee/administration/monitoring/prometheus/node_exporter.html
              ################################################################################

              node_exporter['enable'] = false

              ################################################################################
              ## Prometheus Redis exporter
              ##! Docs: https://docs.gitlab.com/ee/administration/monitoring/prometheus/redis_exporter.html
              ################################################################################

              redis_exporter['enable'] = false

              ################################################################################
              ## Prometheus Postgres exporter
              ##! Docs: https://docs.gitlab.com/ee/administration/monitoring/prometheus/postgres_exporter.html
              ################################################################################

              postgres_exporter['enable'] = false

              ################################################################################
              ## Prometheus Gitlab exporter
              ##! Docs: https://docs.gitlab.com/ee/administration/monitoring/prometheus/gitlab_exporter.html
              ################################################################################

              gitlab_exporter['enable'] = true

              ##! Advanced settings. Should be changed only if absolutely needed.
              gitlab_exporter['listen_address'] = '0.0.0.0'
              gitlab_exporter['listen_port'] = '9168'

              # To completely disable prometheus, and all of it's exporters, set to false
              prometheus_monitoring['enable'] = false

              ################################################################################
              ## Gitaly
              ##! Docs: https://docs.gitlab.com/ee/administration/gitaly/configure_gitaly.html
              ################################################################################

              gitaly['configuration'] = {
                prometheus_listen_addr: '0.0.0.0:9236',
              }
            '';
          };
          extraOptions = [
            "--shm-size=256m"
            "--cpus=1"
            "--memory-reservation=3891m"
            "--memory=4096m"
          ];
          image = (import ./variables.nix).gitlab_image;
        };
      };
    };
  };

  networking = {
    firewall = {
      allowedTCPPorts = [ 8181 ];
    };
  };

  systemd.services = {
    gitlab-application-settings = {
      after = [ "${CONTAINERS_BACKEND}-gitlab.service" ];
      serviceConfig = {
        Type = "oneshot";
        EnvironmentFile = config.sops.secrets."gitlab/application/envs".path;
      };
      script = ''
        export GITLAB_ADDRESS=${IP_ADDRESS}:8181

        while ! ${pkgs.curl}/bin/curl --silent --request GET http://$GITLAB_ADDRESS/-/health |
          ${pkgs.gnugrep}/bin/grep "GitLab OK"
        do
          ${pkgs.coreutils}/bin/echo "Waiting for GitLab availability."
          ${pkgs.coreutils}/bin/sleep 1
        done

        json_gitlab_oauth_token()
        {
        ${pkgs.coreutils}/bin/cat <<EOF
          {
            "grant_type": "password",
            "username": "root",
            "password": "$GITLAB_PASSWORD"
          }
        EOF
        }

        export GITLAB_OAUTH_TOKEN=$(
          ${pkgs.curl}/bin/curl --silent --request POST \
            --url http://$GITLAB_ADDRESS/oauth/token \
            --header "content-type: application/json" \
            --data "$(json_gitlab_oauth_token)" |
          ${pkgs.jq}/bin/jq --raw-output .access_token
        )

        ${pkgs.curl}/bin/curl --silent --request PUT \
          --url http://$GITLAB_ADDRESS/api/v4/application/settings \
          --header "Authorization: Bearer $GITLAB_OAUTH_TOKEN" \
          --data "signup_enabled=false"

        ${pkgs.curl}/bin/curl --silent --request POST \
          --url http://$GITLAB_ADDRESS/oauth/revoke \
          --form "token=$GITLAB_OAUTH_TOKEN"
      '';
      wantedBy = [ "${CONTAINERS_BACKEND}-gitlab.service" ];
    };
  };

  services = {
    nginx = let
      CONFIG_SERVER = ''
        ssl_session_timeout 1d;
        ssl_session_cache shared:MozSSL:10m; # about 40000 sessions
        ssl_session_tickets off;

        ssl_prefer_server_ciphers off;

        # HSTS (ngx_http_headers_module is required) (63072000 seconds)
        add_header Strict-Transport-Security "max-age=63072000" always;

        # OCSP stapling
        ssl_stapling on;
        ssl_stapling_verify on;

        # Authentication based on a client certificate
        # ssl_client_certificate /mnt/ssd/services/nginx/ca.pem;
        # ssl_verify_client on;
      '';
      CONFIG_LOCATION = ''
        proxy_set_header Host $host; # required for docker client's sake (registry.domain.com)
        proxy_set_header X-Real-IP $remote_addr; # pass on real client's IP
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
      '';
    in {
      upstreams."gitlab-workhorse" = {
        servers = let
          GITLAB_WORKHORSE_ADDRESS = "${IP_ADDRESS}:8181";
        in { "${GITLAB_WORKHORSE_ADDRESS} fail_timeout=0" = {}; };
      };

      commonHttpConfig = ''
        map $http_upgrade $connection_upgrade_gitlab_ssl {
          default upgrade;
          ""      close;
        }

        # NGINX 'combined' log format with filtered query strings
        log_format gitlab_ssl_access $remote_addr - $remote_user [$time_local] "$request_method $gitlab_ssl_filtered_request_uri $server_protocol" $status $body_bytes_sent "$gitlab_ssl_filtered_http_referer" "$http_user_agent";

        # Remove private_token from the request URI
        # In:  /foo?private_token=unfiltered&authenticity_token=unfiltered&feed_token=unfiltered&...
        # Out: /foo?private_token=[FILTERED]&authenticity_token=unfiltered&feed_token=unfiltered&...
        map $request_uri $gitlab_ssl_temp_request_uri_1 {
          default $request_uri;
          ~(?i)^(?<start>.*)(?<temp>[\?&]private[\-_]token)=[^&]*(?<rest>.*)$ "$start$temp=[FILTERED]$rest";
        }

        # Remove authenticity_token from the request URI
        # In:  /foo?private_token=[FILTERED]&authenticity_token=unfiltered&feed_token=unfiltered&...
        # Out: /foo?private_token=[FILTERED]&authenticity_token=[FILTERED]&feed_token=unfiltered&...
        map $gitlab_ssl_temp_request_uri_1 $gitlab_ssl_temp_request_uri_2 {
          default $gitlab_ssl_temp_request_uri_1;
          ~(?i)^(?<start>.*)(?<temp>[\?&]authenticity[\-_]token)=[^&]*(?<rest>.*)$ "$start$temp=[FILTERED]$rest";
        }

        # Remove feed_token from the request URI
        # In:  /foo?private_token=[FILTERED]&authenticity_token=[FILTERED]&feed_token=unfiltered&...
        # Out: /foo?private_token=[FILTERED]&authenticity_token=[FILTERED]&feed_token=[FILTERED]&...
        map $gitlab_ssl_temp_request_uri_2 $gitlab_ssl_filtered_request_uri {
          default $gitlab_ssl_temp_request_uri_2;
          ~(?i)^(?<start>.*)(?<temp>[\?&]feed[\-_]token)=[^&]*(?<rest>.*)$ "$start$temp=[FILTERED]$rest";
        }

        # A version of the referer without the query string
        map $http_referer $gitlab_ssl_filtered_http_referer {
          default $http_referer;
          ~^(?<temp>.*)\? $temp;
        }
      '';

      virtualHosts."gitlab.${DOMAIN_NAME_INTERNAL}" = {
        listen = [
          { addr = "${IP_ADDRESS}"; port = 80; }
          { addr = "${IP_ADDRESS}"; port = 443; ssl = true; }
        ];

        http2 = true;
        kTLS = true;
        forceSSL = true;
        sslCertificate = "/mnt/ssd/services/nginx/server.crt";
        sslCertificateKey = "/mnt/ssd/services/nginx/server.key";
        # verify chain of trust of OCSP response using Root CA and Intermediate certs
        sslTrustedCertificate = "/mnt/ssd/services/nginx/ca.pem";

        extraConfig = ''
          ${CONFIG_SERVER}
        '';

        locations."/" = {
          extraConfig = ''
            ${CONFIG_LOCATION}

            access_log /var/log/nginx/gitlab.workhorse.access.log gitlab_ssl_access;
            error_log /var/log/nginx/gitlab.workhorse.error.log;

            client_max_body_size 700m;
            gzip off;

            # Some requests take more than 30 seconds.
            proxy_read_timeout 300;
            proxy_connect_timeout 300;
            proxy_redirect off;

            proxy_http_version 1.1;

            proxy_set_header X-Forwarded-Ssl on;
            proxy_set_header Upgrade $http_upgrade;
            proxy_set_header Connection $connection_upgrade_gitlab_ssl;

            proxy_cache off;
          '';
          proxyPass = "http://gitlab-workhorse";
        };
      };

      virtualHosts."registry.${DOMAIN_NAME_INTERNAL}" = {
        listen = [
          { addr = "${IP_ADDRESS}"; port = 80; }
          { addr = "${IP_ADDRESS}"; port = 443; ssl = true; }
        ];

        http2 = true;
        kTLS = true;
        forceSSL = true;
        sslCertificate = "/mnt/ssd/services/nginx/server.crt";
        sslCertificateKey = "/mnt/ssd/services/nginx/server.key";
        # verify chain of trust of OCSP response using Root CA and Intermediate certs
        sslTrustedCertificate = "/mnt/ssd/services/nginx/ca.pem";

        extraConfig = ''
          ${CONFIG_SERVER}
        '';

        locations."/" = {
          extraConfig = ''
            ${CONFIG_LOCATION}

            access_log /var/log/nginx/gitlab.registry.access.log;
            error_log /var/log/nginx/gitlab.registry.error.log;

            client_max_body_size 250m;
            chunked_transfer_encoding on;

            proxy_read_timeout 900;
          '';
          proxyPass = "http://127.0.0.1:5000";
        };
      };

      virtualHosts."pages.${DOMAIN_NAME_INTERNAL}" = {
        listen = [
          { addr = "${IP_ADDRESS}"; port = 80; }
          { addr = "${IP_ADDRESS}"; port = 443; ssl = true; }
        ];

        http2 = true;
        kTLS = true;
        forceSSL = true;
        sslCertificate = "/mnt/ssd/services/nginx/server.crt";
        sslCertificateKey = "/mnt/ssd/services/nginx/server.key";
        # verify chain of trust of OCSP response using Root CA and Intermediate certs
        sslTrustedCertificate = "/mnt/ssd/services/nginx/ca.pem";

        extraConfig = ''
          ${CONFIG_SERVER}
        '';

        locations."/" = {
          extraConfig = ''
            ${CONFIG_LOCATION}

            access_log /var/log/nginx/gitlab.pages.access.log;
            error_log /var/log/nginx/gitlab.pages.error.log;

            proxy_cache off;
          '';
          proxyPass = "http://127.0.0.1:8090";
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

  sops.secrets = {
    "gitlab/application/envs" = {
      mode = "0400";
      owner = config.users.users.root.name;
      group = config.users.users.root.group;
    };
  };

  systemd.services = {
    gitlab-1password = {
      after = [ "${CONTAINERS_BACKEND}-gitlab.service" ];
      preStart = "${pkgs.coreutils}/bin/sleep $((RANDOM % 33))";
      serviceConfig = {
        Type = "oneshot";
        EnvironmentFile = [
          config.sops.secrets."1password/application/envs".path
          config.sops.secrets."gitlab/application/envs".path
          config.sops.secrets."gitlab/minio/envs".path
          config.sops.secrets."gitlab/postgres/envs".path
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

        ${pkgs._1password}/bin/op item get GitLab \
          --vault Server \
          --session $SESSION_TOKEN > /dev/null

        if [ $? != 0 ]
        then
          ${pkgs._1password}/bin/op item template get Login --session $SESSION_TOKEN | ${pkgs._1password}/bin/op item create --vault Server - \
            --title GitLab \
            --url https://gitlab.${DOMAIN_NAME_INTERNAL} \
            username=root \
            password=$GITLAB_PASSWORD \
            MinIO.'Access Key'[text]=$MINIO_SERVICE_ACCOUNT_ACCESS_KEY \
            MinIO.'Secret Key'[password]=$MINIO_SERVICE_ACCOUNT_SECRET_KEY \
            Postgres.'Connection command'[password]="PGPASSWORD='$POSTGRESQL_PASSWORD' psql -h ${IP_ADDRESS} -p ${toString config.services.postgresql.port} -U $POSTGRESQL_USERNAME $POSTGRESQL_DATABASE" \
            --session $SESSION_TOKEN > /dev/null
          ${pkgs.coreutils}/bin/echo "Item created successfully."
        else
          ${pkgs._1password}/bin/op item edit GitLab \
            --vault Server \
            --url https://gitlab.${DOMAIN_NAME_INTERNAL} \
            username=root \
            password=$GITLAB_PASSWORD \
            MinIO.'Access Key'[text]=$MINIO_SERVICE_ACCOUNT_ACCESS_KEY \
            MinIO.'Secret Key'[password]=$MINIO_SERVICE_ACCOUNT_SECRET_KEY \
            Postgres.'Connection command'[password]="PGPASSWORD='$POSTGRESQL_PASSWORD' psql -h ${IP_ADDRESS} -p ${toString config.services.postgresql.port} -U $POSTGRESQL_USERNAME $POSTGRESQL_DATABASE" \
            --session $SESSION_TOKEN > /dev/null
          ${pkgs.coreutils}/bin/echo "Item updated successfully."
        fi
      '';
      wantedBy = [ "${CONTAINERS_BACKEND}-gitlab.service" ];
    };
  };

  services = {
    prometheus = {
      scrapeConfigs = [
        {
          job_name = "gitlab-registry";
          scheme = "http";
          static_configs = [{
            targets = [ "127.0.0.1:5001" ];
          }];
          metrics_path = "/metrics";
        }
        {
          job_name = "gitlab-rails";
          scheme = "http";
          static_configs = [{
            targets = [ "${IP_ADDRESS}:8181" ];
          }];
          metrics_path = "/-/metrics";
        }
        {
          job_name = "gitlab-workhorse";
          scheme = "http";
          static_configs = [{
            targets = [ "127.0.0.1:9229" ];
          }];
          metrics_path = "/metrics";
        }
        {
          job_name = "gitlab-puma";
          scheme = "http";
          static_configs = [{
            targets = [ "127.0.0.1:8083" ];
          }];
          metrics_path = "/metrics";
        }
        {
          job_name = "gitlab-sidekiq";
          scheme = "http";
          static_configs = [{
            targets = [ "127.0.0.1:8082" ];
          }];
          metrics_path = "/metrics";
        }
        {
          job_name = "gitlab-pages";
          scheme = "http";
          static_configs = [{
            targets = [ "127.0.0.1:9235" ];
          }];
          metrics_path = "/metrics";
        }
        {
          job_name = "gitlab-exporter-database";
          scheme = "http";
          static_configs = [{
            targets = [ "127.0.0.1:9168" ];
          }];
          metrics_path = "/database";
        }
        {
          job_name = "gitlab-exporter-sidekiq";
          scheme = "http";
          static_configs = [{
            targets = [ "127.0.0.1:9168" ];
          }];
          metrics_path = "/sidekiq";
        }
        {
          job_name = "gitlab-gitaly";
          scheme = "http";
          static_configs = [{
            targets = [ "127.0.0.1:9236" ];
          }];
          metrics_path = "/metrics";
        }
      ];
    };
  };

  systemd.services = {
    gitlab-integrations-mattermost-notifications = {
      after = [
        "mattermost-configure.service"
        "${CONTAINERS_BACKEND}-gitlab.service"
      ];
      serviceConfig = {
        Type = "oneshot";
        EnvironmentFile = [
          config.sops.secrets."mattermost/application/envs".path
          config.sops.secrets."gitlab/application/envs".path
        ];
      };
      script = ''
        export MATTERMOST_ADDRESS=${IP_ADDRESS}:8065

        while ! ${pkgs.curl}/bin/curl --silent --request GET http://$MATTERMOST_ADDRESS/mattermost/api/v4/system/ping |
          ${pkgs.gnugrep}/bin/grep OK
        do
          ${pkgs.coreutils}/bin/echo "Waiting for Mattermost availability."
          ${pkgs.coreutils}/bin/sleep 1
        done

        export MATTERMOST_TEAM=${lib.strings.stringAsChars (x: if x == "." then "-" else x) DOMAIN_NAME_INTERNAL}
        export MATTERMOST_CHANNEL_NAME="GitLab"
        export MATTERMOST_CHANNEL=$(
          ${pkgs.coreutils}/bin/echo $MATTERMOST_CHANNEL_NAME |
          ${pkgs.gawk}/bin/awk '{print tolower($0)}' |
          ${pkgs.gnused}/bin/sed 's/ /-/g'
        )

        case `
          ${pkgs.${CONTAINERS_BACKEND}}/bin/${CONTAINERS_BACKEND} exec mattermost mmctl channel list \
            $MATTERMOST_TEAM \
            --local |
          ${pkgs.gnugrep}/bin/grep $MATTERMOST_CHANNEL > /dev/null
          ${pkgs.coreutils}/bin/echo $?
        ` in
          "1" )
            ${pkgs.${CONTAINERS_BACKEND}}/bin/${CONTAINERS_BACKEND} exec mattermost mmctl channel create \
              --team $MATTERMOST_TEAM \
              --name $MATTERMOST_CHANNEL \
              --display-name "$MATTERMOST_CHANNEL_NAME" \
              --private \
              --local
          ;;
          "0" )
            ${pkgs.${CONTAINERS_BACKEND}}/bin/${CONTAINERS_BACKEND} exec mattermost mmctl channel rename \
              $MATTERMOST_TEAM:$MATTERMOST_CHANNEL \
              --display-name "$MATTERMOST_CHANNEL_NAME" \
              --local

            case `
              ${pkgs.${CONTAINERS_BACKEND}}/bin/${CONTAINERS_BACKEND} exec mattermost mmctl channel search \
                --team $MATTERMOST_TEAM \
                $MATTERMOST_CHANNEL \
                --json \
                --local |
              ${pkgs.jq}/bin/jq --raw-output .type
            ` in
              "O" )
                ${pkgs.${CONTAINERS_BACKEND}}/bin/${CONTAINERS_BACKEND} exec mattermost mmctl channel modify \
                  $MATTERMOST_TEAM:$MATTERMOST_CHANNEL \
                  --private \
                  --local
                ${pkgs.coreutils}/bin/echo "'$MATTERMOST_CHANNEL' channel converted to private"
              ;;
              "P" )
                ${pkgs.coreutils}/bin/echo "'$MATTERMOST_CHANNEL' channel is already private"
              ;;
            esac

          ;;
        esac

        ${pkgs.${CONTAINERS_BACKEND}}/bin/${CONTAINERS_BACKEND} exec mattermost mmctl channel users add \
          $MATTERMOST_TEAM:$MATTERMOST_CHANNEL \
          $MATTERMOST_USERNAME@${DOMAIN_NAME_INTERNAL} \
          --local

        export MATTERMOST_WEBHOOK_NAME=$MATTERMOST_CHANNEL_NAME

        case `
          ${pkgs.${CONTAINERS_BACKEND}}/bin/${CONTAINERS_BACKEND} exec mattermost mmctl webhook list \
            $MATTERMOST_TEAM \
            --local |
          ${pkgs.gnugrep}/bin/grep $MATTERMOST_WEBHOOK_NAME > /dev/null
          ${pkgs.coreutils}/bin/echo $?
        ` in
          "1" )
            ${pkgs.${CONTAINERS_BACKEND}}/bin/${CONTAINERS_BACKEND} exec mattermost mmctl webhook create-incoming \
              --user $MATTERMOST_USERNAME@${DOMAIN_NAME_INTERNAL} \
              --display-name $MATTERMOST_WEBHOOK_NAME \
              --channel $MATTERMOST_TEAM:$MATTERMOST_CHANNEL \
              --lock-to-channel \
              --local
          ;;
          "0" )
            export MATTERMOST_WEBHOOK_ID=$(
              ${pkgs.${CONTAINERS_BACKEND}}/bin/${CONTAINERS_BACKEND} exec mattermost mmctl webhook list \
                $MATTERMOST_TEAM \
                --local |
              ${pkgs.gnugrep}/bin/grep $MATTERMOST_WEBHOOK_NAME |
              ${pkgs.gawk}/bin/awk '{ print $3 }' |
              ${pkgs.gnused}/bin/sed 's/(//g'
            )
            ${pkgs.${CONTAINERS_BACKEND}}/bin/${CONTAINERS_BACKEND} exec mattermost mmctl webhook modify-incoming \
              $MATTERMOST_WEBHOOK_ID \
              --display-name $MATTERMOST_WEBHOOK_NAME \
              --channel $MATTERMOST_TEAM:$MATTERMOST_CHANNEL \
              --lock-to-channel \
              --local
          ;;
        esac

        export MATTERMOST_WEBHOOK_ID=$(
          ${pkgs.${CONTAINERS_BACKEND}}/bin/${CONTAINERS_BACKEND} exec mattermost mmctl webhook list \
            $MATTERMOST_TEAM \
            --local |
          ${pkgs.gnugrep}/bin/grep $MATTERMOST_WEBHOOK_NAME |
          ${pkgs.gawk}/bin/awk '{ print $3 }' |
          ${pkgs.gnused}/bin/sed 's/(//g'
        )

        export GITLAB_ADDRESS=${IP_ADDRESS}:8181

        while ! ${pkgs.curl}/bin/curl --silent --request GET http://$GITLAB_ADDRESS/-/health |
          ${pkgs.gnugrep}/bin/grep "GitLab OK"
        do
          ${pkgs.coreutils}/bin/echo "Waiting for GitLab availability."
          ${pkgs.coreutils}/bin/sleep 1
        done

        json_gitlab_oauth_token()
        {
        ${pkgs.coreutils}/bin/cat <<EOF
          {
            "grant_type": "password",
            "username": "root",
            "password": "$GITLAB_PASSWORD"
          }
        EOF
        }

        export GITLAB_OAUTH_TOKEN=$(
          ${pkgs.curl}/bin/curl --silent --request POST \
            --url http://$GITLAB_ADDRESS/oauth/token \
            --header "content-type: application/json" \
            --data "$(json_gitlab_oauth_token)" |
          ${pkgs.jq}/bin/jq --raw-output .access_token
        )

        ${pkgs.curl}/bin/curl --silent --request PUT \
          --url http://$GITLAB_ADDRESS/api/v4/application/settings \
          --header "Authorization: Bearer $GITLAB_OAUTH_TOKEN" \
          --data "allow_local_requests_from_web_hooks_and_services=true"

        json_mattermost_notifications()
        {
        ${pkgs.coreutils}/bin/cat <<EOF
          {
            "push_events": true,
            "push_channel": "$MATTERMOST_CHANNEL",
            "issues_events": true,
            "issue_channel": "$MATTERMOST_CHANNEL",
            "confidential_issues_events": true,
            "confidential_issue_channel": "$MATTERMOST_CHANNEL",
            "merge_requests_events": true,
            "merge_request_channel": "$MATTERMOST_CHANNEL",
            "note_events": true,
            "note_channel": "$MATTERMOST_CHANNEL",
            "confidential_note_events": true,
            "confidential_note_channel": "$MATTERMOST_CHANNEL",
            "tag_push_events": true,
            "tag_push_channel": "$MATTERMOST_CHANNEL",
            "pipeline_events": true,
            "pipeline_channel": "$MATTERMOST_CHANNEL",
            "wiki_page_events": true,
            "wiki_page_channel": "$MATTERMOST_CHANNEL",
            "deployment_events": true,
            "deployment_channel": "$MATTERMOST_CHANNEL",
            "incident_events": true,
            "incident_channel": "$MATTERMOST_CHANNEL",
            "notify_only_broken_pipelines": false,
            "branches_to_be_notified": "default",
            "labels_to_be_notified": "",
            "labels_to_be_notified_behavior": "",
            "webhook": "http://$MATTERMOST_ADDRESS/mattermost/hooks/$MATTERMOST_WEBHOOK_ID",
            "username": ""
          }
        EOF
        }

        ${pkgs.curl}/bin/curl --silent --request PUT \
          --url http://$GITLAB_ADDRESS/api/v4/projects/64/integrations/mattermost \
          --header "Authorization: Bearer $GITLAB_OAUTH_TOKEN" \
          --header "content-type: application/json" \
          --data "$(json_mattermost_notifications)"

        ${pkgs.curl}/bin/curl --silent --request POST \
          --url http://$GITLAB_ADDRESS/oauth/revoke \
          --form "token=$GITLAB_OAUTH_TOKEN"
      '';
      wantedBy = [
        "mattermost-configure.service"
        "${CONTAINERS_BACKEND}-gitlab.service"
      ];
    };
  };

  systemd.services = {
    gitlab-integrations-mattermost-slash-commands = {
      after = [
        "mattermost-configure.service"
        "${CONTAINERS_BACKEND}-gitlab.service"
      ];
      serviceConfig = {
        Type = "oneshot";
        EnvironmentFile = [
          config.sops.secrets."mattermost/application/envs".path
          config.sops.secrets."gitlab/application/envs".path
        ];
      };
      script = ''
        export MATTERMOST_ADDRESS=${IP_ADDRESS}:8065

        while ! ${pkgs.curl}/bin/curl --silent --request GET http://$MATTERMOST_ADDRESS/mattermost/api/v4/system/ping |
          ${pkgs.gnugrep}/bin/grep OK
        do
          ${pkgs.coreutils}/bin/echo "Waiting for Mattermost availability."
          ${pkgs.coreutils}/bin/sleep 1
        done

        export MATTERMOST_TEAM=${lib.strings.stringAsChars (x: if x == "." then "-" else x) DOMAIN_NAME_INTERNAL}
        export MATTERMOST_COMMAND_TITLE="GitLab / Documentation / wiki"

        export GITLAB_ADDRESS=${IP_ADDRESS}:8181

        case `
          ${pkgs.${CONTAINERS_BACKEND}}/bin/${CONTAINERS_BACKEND} exec mattermost mmctl command list \
            $MATTERMOST_TEAM \
            --local |
          ${pkgs.gnugrep}/bin/grep "$MATTERMOST_COMMAND_TITLE" > /dev/null
          ${pkgs.coreutils}/bin/echo $?
        ` in
          "1" )
            ${pkgs.${CONTAINERS_BACKEND}}/bin/${CONTAINERS_BACKEND} exec mattermost mmctl command create \
              $MATTERMOST_TEAM \
              --creator $MATTERMOST_USERNAME \
              --title "$MATTERMOST_COMMAND_TITLE" \
              --description "Perform common operations on GitLab project: Documentation / wiki" \
              --trigger-word documentation/wiki \
              --url http://$GITLAB_ADDRESS/api/v4/projects/64/integrations/mattermost_slash_commands/trigger \
              --post \
              --response-username GitLab \
              --icon http://$GITLAB_ADDRESS/assets/gitlab_logo-2957169c8ef64c58616a1ac3f4fc626e8a35ce4eb3ed31bb0d873712f2a041a0.png \
              --autocomplete \
              --autocompleteHint [help] \
              --autocompleteDesc "Perform common operations on GitLab project: Documentation / wiki" \
              --local
          ;;
          "0" )
            export MATTERMOST_COMMAND_ID=$(
              ${pkgs.${CONTAINERS_BACKEND}}/bin/${CONTAINERS_BACKEND} exec mattermost mmctl command list \
                $MATTERMOST_TEAM \
                --local |
              ${pkgs.gnugrep}/bin/grep "$MATTERMOST_COMMAND_TITLE" |
              ${pkgs.gawk}/bin/awk '{ print $1 }' |
              ${pkgs.gnused}/bin/sed 's/://g'
            )
            ${pkgs.${CONTAINERS_BACKEND}}/bin/${CONTAINERS_BACKEND} exec mattermost mmctl command modify \
              $MATTERMOST_COMMAND_ID \
              --creator $MATTERMOST_USERNAME \
              --title "$MATTERMOST_COMMAND_TITLE" \
              --description "Perform common operations on GitLab project: Documentation / wiki" \
              --trigger-word documentation/wiki \
              --url http://$GITLAB_ADDRESS/api/v4/projects/64/integrations/mattermost_slash_commands/trigger \
              --post \
              --response-username GitLab \
              --icon http://$GITLAB_ADDRESS/assets/gitlab_logo-2957169c8ef64c58616a1ac3f4fc626e8a35ce4eb3ed31bb0d873712f2a041a0.png \
              --autocomplete \
              --autocompleteHint [help] \
              --autocompleteDesc "Perform common operations on GitLab project: Documentation / wiki" \
              --local
          ;;
        esac

        export MATTERMOST_COMMAND_ID=$(
          ${pkgs.${CONTAINERS_BACKEND}}/bin/${CONTAINERS_BACKEND} exec mattermost mmctl command list \
            $MATTERMOST_TEAM \
            --local |
          ${pkgs.gnugrep}/bin/grep "$MATTERMOST_COMMAND_TITLE" |
          ${pkgs.gawk}/bin/awk '{ print $1 }' |
          ${pkgs.gnused}/bin/sed 's/://g'
        )

        export MATTERMOST_COMMAND_TOKEN=$(
          ${pkgs.${CONTAINERS_BACKEND}}/bin/${CONTAINERS_BACKEND} exec mattermost mmctl command show \
            $MATTERMOST_COMMAND_ID \
            --json \
            --local |
          ${pkgs.jq}/bin/jq --raw-output .token
        )

        while ! ${pkgs.curl}/bin/curl --silent --request GET http://$GITLAB_ADDRESS/-/health |
          ${pkgs.gnugrep}/bin/grep "GitLab OK"
        do
          ${pkgs.coreutils}/bin/echo "Waiting for GitLab availability."
          ${pkgs.coreutils}/bin/sleep 1
        done

        json_gitlab_oauth_token()
        {
        ${pkgs.coreutils}/bin/cat <<EOF
          {
            "grant_type": "password",
            "username": "root",
            "password": "$GITLAB_PASSWORD"
          }
        EOF
        }

        export GITLAB_OAUTH_TOKEN=$(
          ${pkgs.curl}/bin/curl --silent --request POST \
            --url http://$GITLAB_ADDRESS/oauth/token \
            --header "content-type: application/json" \
            --data "$(json_gitlab_oauth_token)" |
          ${pkgs.jq}/bin/jq --raw-output .access_token
        )

        ${pkgs.curl}/bin/curl --silent --request PUT \
          --url http://$GITLAB_ADDRESS/api/v4/projects/64/integrations/mattermost-slash-commands \
          --header "Authorization: Bearer $GITLAB_OAUTH_TOKEN" \
          --form "token=$MATTERMOST_COMMAND_TOKEN"

        ${pkgs.curl}/bin/curl --silent --request POST \
          --url http://$GITLAB_ADDRESS/oauth/revoke \
          --form "token=$GITLAB_OAUTH_TOKEN"
      '';
      wantedBy = [
        "mattermost-configure.service"
        "${CONTAINERS_BACKEND}-gitlab.service"
      ];
    };
  };

  services = {
    grafana-agent = {
      settings = {
        logs = {
          configs = [{
            name = "gitlab";
            clients = [{
              url = "http://${config.services.loki.configuration.server.http_listen_address}:${toString config.services.loki.configuration.server.http_listen_port}/loki/api/v1/push";
            }];
            positions = {
              filename = "/var/lib/private/grafana-agent/positions/gitlab.yml";
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
                  regex = "(gitlab-prepare|gitlab-minio|gitlab-postgres|${CONTAINERS_BACKEND}-gitlab|gitlab-application-settings|gitlab-1password|gitlab-integrations-mattermost-notifications|gitlab-integrations-mattermost-slash-commands).service";
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
