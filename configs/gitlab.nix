{ config, pkgs, ... }:

let
  CONTAINERS_BACKEND = config.virtualisation.oci-containers.backend;
  IP_ADDRESS = (import ./connection-parameters.nix).ip_address;
  REDIS_INSTANCE = (import /etc/nixos/variables.nix).redis_instance;
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

        while true; do
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

            ${pkgs.minio-client}/bin/mc admin user svcacct info $ALIAS $GITLAB_MINIO_ACCESS_KEY

            if [ $? != 0 ]
            then
              ${pkgs.minio-client}/bin/mc admin user svcacct add \
                --access-key $GITLAB_MINIO_ACCESS_KEY \
                --secret-key $GITLAB_MINIO_SECRET_KEY \
                --policy ${policy_json} \
                --comment gitlab \
                $ALIAS \
                $MINIO_ROOT_USER > /dev/null

              ${pkgs.coreutils}/bin/echo "Service account created successfully \`$GITLAB_MINIO_ACCESS_KEY\`."
            else
              ${pkgs.minio-client}/bin/mc admin user svcacct edit \
                --secret-key $GITLAB_MINIO_SECRET_KEY \
                --policy ${policy_json} \
                $ALIAS \
                $GITLAB_MINIO_ACCESS_KEY
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
        while ! ${pkgs.netcat}/bin/nc -w 1 -v -z ${IP_ADDRESS} ${toString config.services.postgresql.port}; do
          ${pkgs.coreutils}/bin/echo "Waiting for PostgreSQL availability."
          ${pkgs.coreutils}/bin/sleep 1
        done

        ${pkgs.sudo}/bin/sudo -u postgres ${pkgs.postgresql_14}/bin/psql --variable=ON_ERROR_STOP=1 <<-EOSQL 2> /dev/null
          DO
          \$do$
          BEGIN
              IF EXISTS (
                  SELECT FROM pg_catalog.pg_roles
                  WHERE rolname = '$GITLAB_POSTGRES_USERNAME'
              )
              THEN
                  RAISE NOTICE 'role "$GITLAB_POSTGRES_USERNAME" already exists, skipping';
              ELSE
                  CREATE ROLE $GITLAB_POSTGRES_USERNAME WITH
                      LOGIN
                      ENCRYPTED PASSWORD '$GITLAB_POSTGRES_PASSWORD';
              END IF;
          END
          \$do$;

          SELECT 'CREATE DATABASE gitlab OWNER $GITLAB_POSTGRES_USERNAME'
              WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = 'gitlab');
          \gexec

          \c gitlab
          CREATE EXTENSION IF NOT EXISTS pg_trgm;
          CREATE EXTENSION IF NOT EXISTS btree_gist;
        EOSQL
        ${pkgs.coreutils}/bin/echo "GitLab account created successfully."
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
    "redis/database/file/password" = {
      mode = "0400";
      owner = config.services.redis.servers.${REDIS_INSTANCE}.user;
      group = config.services.redis.servers.${REDIS_INSTANCE}.user;
    };
  };

  virtualisation = {
    oci-containers = {
      containers = {
        gitlab = {
          autoStart = true;
          ports = [
            "127.0.0.1:8181:8181"
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
            "/mnt/ssd/services/gitlab/config:/etc/gitlab"
            "/mnt/ssd/services/gitlab/logs:/var/log/gitlab"
            "/mnt/ssd/services/gitlab/data:/var/opt/gitlab"
            "${config.sops.secrets."gitlab/minio/file/access_key".path}:/run/secrets/minio_access_key"
            "${config.sops.secrets."gitlab/minio/file/secret_key".path}:/run/secrets/minio_secret_key"
            "${config.sops.secrets."gitlab/application/file/password".path}:/run/secrets/gitlab_password"
            "${config.sops.secrets."gitlab/application/file/token".path}:/run/secrets/gitlab_token"
            "${config.sops.secrets."gitlab/postgres/file/username".path}:/run/secrets/postgres_username"
            "${config.sops.secrets."gitlab/postgres/file/password".path}:/run/secrets/postgres_password"
            "${config.sops.secrets."redis/database/file/password".path}:/run/secrets/redis_password"
          ];
          environment = let
            MINIO_REGION = config.virtualisation.oci-containers.containers.minio.environment.MINIO_REGION;
          in {
            GITLAB_OMNIBUS_CONFIG = ''
              external_url 'http://gitlab.${DOMAIN_NAME_INTERNAL}'

              gitlab_rails['smtp_enable'] = false
              gitlab_rails['gitlab_email_enabled'] = false

              gitlab_rails['monitoring_whitelist'] = ['0.0.0.0/0']

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

              gitlab_rails['backup_upload_connection'] = {
                'provider' => 'AWS',
                'endpoint' => 'http://${IP_ADDRESS}:9000',
                'region' => '${MINIO_REGION}',
                'path_style' => 'true',
                'aws_access_key_id' => File.read('/run/secrets/minio_access_key').gsub("\n", ""),
                'aws_secret_access_key' => File.read('/run/secrets/minio_secret_key').gsub("\n", "")
              }
              gitlab_rails['backup_upload_remote_directory'] = 'gitlab-backup'

              gitlab_rails['initial_root_password'] = File.read('/run/secrets/gitlab_password').gsub("\n", "")
              gitlab_rails['initial_shared_runners_registration_token'] = File.read('/run/secrets/gitlab_token').gsub("\n", "")
              gitlab_rails['store_initial_root_password'] = false

              gitlab_rails['db_database'] = 'gitlab'
              gitlab_rails['db_username'] = File.read('/run/secrets/postgres_username').gsub("\n", "")
              gitlab_rails['db_password'] = File.read('/run/secrets/postgres_password').gsub("\n", "")
              gitlab_rails['db_host'] = '${IP_ADDRESS}'
              gitlab_rails['db_port'] = ${toString config.services.postgresql.port}

              gitlab_rails['redis_host'] = '${config.services.redis.servers.${REDIS_INSTANCE}.bind}'
              gitlab_rails['redis_port'] = ${toString config.services.redis.servers.${REDIS_INSTANCE}.port}
              gitlab_rails['redis_password'] = File.read('/run/secrets/redis_password').gsub("\n", "")

              registry_external_url 'http://registry.${DOMAIN_NAME_INTERNAL}'
              registry['registry_http_addr'] = '0.0.0.0:5000'
              registry['debug_addr'] = '0.0.0.0:5001'
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

              gitlab_workhorse['listen_network'] = 'tcp'
              gitlab_workhorse['listen_addr'] = '0.0.0.0:8181'
              gitlab_workhorse['prometheus_listen_addr'] = '0.0.0.0:9229'
              gitlab_workhorse['image_scaler_max_procs'] = 1

              puma['listen'] = '127.0.0.1'
              puma['port'] = 8080
              puma['exporter_enabled'] = true
              puma['exporter_address'] = '0.0.0.0'
              puma['exporter_port'] = 8083

              sidekiq['listen_address'] = '0.0.0.0'
              sidekiq['listen_port'] = 8082
              sidekiq['health_checks_listen_address'] = '127.0.0.1'
              sidekiq['health_checks_listen_port'] = 8092

              postgresql['enable'] = false
              redis['enable'] = false
              nginx['enable'] = false

              pages_external_url 'http://pages.${DOMAIN_NAME_INTERNAL}'
              gitlab_pages['enable'] = true
              gitlab_pages['status_uri'] = '/@status'
              gitlab_pages['listen_proxy'] = '0.0.0.0:8090'
              gitlab_pages['metrics_address'] = '0.0.0.0:9235'

              pages_nginx['enable'] = false
              gitlab_rails['gitlab_kas_enabled'] = false
              gitlab_kas['enable'] = false
              prometheus['enable'] = false

              gitlab_rails['prometheus_address'] = '${config.services.prometheus.listenAddress}:${toString config.services.prometheus.port}'

              alertmanager['enable'] = false
              node_exporter['enable'] = false
              redis_exporter['enable'] = false
              postgres_exporter['enable'] = false

              gitlab_exporter['enable'] = true
              gitlab_exporter['listen_address'] = '0.0.0.0'
              gitlab_exporter['listen_port'] = '9168'

              prometheus_monitoring['enable'] = false

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
          image = (import /etc/nixos/variables.nix).gitlab_image;
        };
      };
    };
  };

  services = {
    nginx = {
      upstreams."gitlab-workhorse" = {
        servers = { "127.0.0.1:8181 fail_timeout=0" = {}; };
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
          #ssl_client_certificate /mnt/ssd/services/nginx/ca.pem;
          #ssl_verify_client      on;
        '';

        locations."/" = {
          extraConfig = ''
            access_log /var/log/nginx/gitlab_access.log gitlab_ssl_access;
            error_log  /var/log/nginx/gitlab_error.log;

            client_max_body_size 700m;
            gzip off;

            # Some requests take more than 30 seconds.
            proxy_read_timeout    300;
            proxy_connect_timeout 300;
            proxy_redirect        off;

            proxy_http_version 1.1;

            proxy_set_header Host              $host;
            proxy_set_header X-Real-IP         $remote_addr;
            proxy_set_header X-Forwarded-Ssl   on;
            proxy_set_header X-Forwarded-For   $proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto $scheme;
            proxy_set_header Upgrade           $http_upgrade;
            proxy_set_header Connection        $connection_upgrade_gitlab_ssl;

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
          ssl_client_certificate /mnt/ssd/services/nginx/ca.pem;
          ssl_verify_client      on;
        '';

        locations."/" = {
          extraConfig = ''
            access_log /var/log/nginx/gitlab_registry_access.log;
            error_log  /var/log/nginx/gitlab_registry_error.log;

            client_max_body_size 250m;
            chunked_transfer_encoding on;

            proxy_set_header Host              $host;        # required for docker client's sake
            proxy_set_header X-Real-IP         $remote_addr; # pass on real client's IP
            proxy_set_header X-Forwarded-For   $proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto $scheme;

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
          ssl_client_certificate /mnt/ssd/services/nginx/ca.pem;
          ssl_verify_client      on;
        '';

        locations."/" = {
          extraConfig = ''
            access_log /var/log/nginx/gitlab_pages_access.log;
            error_log  /var/log/nginx/gitlab_pages_error.log;

            proxy_set_header Host              $host;
            proxy_set_header X-Real-IP         $remote_addr;
            proxy_set_header X-Forwarded-For   $proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto $scheme;

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
      preStart = "${pkgs.coreutils}/bin/sleep $((RANDOM % 24))";
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
            --url http://gitlab.${DOMAIN_NAME_INTERNAL} \
            username=root \
            password=$GITLAB_PASSWORD \
            MinIO.'Access Key'[text]=$GITLAB_MINIO_ACCESS_KEY \
            MinIO.'Secret Key'[password]=$GITLAB_MINIO_SECRET_KEY \
            PostgreSQL.'Connection command'[password]="PGPASSWORD='$GITLAB_POSTGRES_PASSWORD' psql -h ${IP_ADDRESS} -p ${toString config.services.postgresql.port} -U $GITLAB_POSTGRES_USERNAME gitlab" \
            --session $SESSION_TOKEN > /dev/null

          ${pkgs.coreutils}/bin/echo "Item created successfully."
        else
          ${pkgs._1password}/bin/op item edit GitLab \
            --vault Server \
            --url http://gitlab.${DOMAIN_NAME_INTERNAL} \
            username=root \
            password=$GITLAB_PASSWORD \
            MinIO.'Access Key'[text]=$GITLAB_MINIO_ACCESS_KEY \
            MinIO.'Secret Key'[password]=$GITLAB_MINIO_SECRET_KEY \
            PostgreSQL.'Connection command'[password]="PGPASSWORD='$GITLAB_POSTGRES_PASSWORD' psql -h ${IP_ADDRESS} -p ${toString config.services.postgresql.port} -U $GITLAB_POSTGRES_USERNAME gitlab" \
            --session $SESSION_TOKEN > /dev/null

          ${pkgs.coreutils}/bin/echo "Item edited successfully."
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
            targets = [ "127.0.0.1:8181" ];
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
                  regex = "(gitlab-prepare|gitlab-minio|gitlab-postgres|${CONTAINERS_BACKEND}-gitlab|gitlab-1password).service";
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
