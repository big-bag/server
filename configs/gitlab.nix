{ config, pkgs, ... }:

let
  CONTAINERS_BACKEND = "${config.virtualisation.oci-containers.backend}";
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

  systemd.services = {
    gitlab-minio = {
      before = [ "${CONTAINERS_BACKEND}-gitlab.service" ];
      serviceConfig = let
        ENTRYPOINT = pkgs.writeTextFile {
          name = "entrypoint.sh";
          text = ''
            #!/bin/bash

            mc alias set $ALIAS http://${toString config.services.minio.listenAddress} $MINIO_ACCESS_KEY $MINIO_SECRET_KEY

            mc mb --ignore-existing $ALIAS/gitlab-artifacts
            mc anonymous set public $ALIAS/gitlab-artifacts

            mc mb --ignore-existing $ALIAS/gitlab-external-diffs
            mc anonymous set public $ALIAS/gitlab-external-diffs

            mc mb --ignore-existing $ALIAS/gitlab-lfs
            mc anonymous set public $ALIAS/gitlab-lfs

            mc mb --ignore-existing $ALIAS/gitlab-uploads
            mc anonymous set public $ALIAS/gitlab-uploads

            mc mb --ignore-existing $ALIAS/gitlab-packages
            mc anonymous set public $ALIAS/gitlab-packages

            mc mb --ignore-existing $ALIAS/gitlab-dependency-proxy
            mc anonymous set public $ALIAS/gitlab-dependency-proxy

            mc mb --ignore-existing $ALIAS/gitlab-terraform-state
            mc anonymous set public $ALIAS/gitlab-terraform-state

            mc mb --ignore-existing $ALIAS/gitlab-ci-secure-files
            mc anonymous set public $ALIAS/gitlab-ci-secure-files

            mc mb --ignore-existing $ALIAS/gitlab-pages
            mc anonymous set public $ALIAS/gitlab-pages

            mc mb --ignore-existing $ALIAS/gitlab-backup
            mc anonymous set public $ALIAS/gitlab-backup

            mc mb --ignore-existing $ALIAS/gitlab-registry
            mc anonymous set public $ALIAS/gitlab-registry
          '';
          executable = true;
        };
        MINIO_CLIENT_IMAGE = (import /etc/nixos/variables.nix).minio_client_image;
      in {
        Type = "oneshot";
        EnvironmentFile = pkgs.writeTextFile {
          name = ".env";
          text = ''
            ALIAS = local
            MINIO_ACCESS_KEY = {{ minio_access_key }}
            MINIO_SECRET_KEY = {{ minio_secret_key }}
          '';
        };
        ExecStart = ''${pkgs.bash}/bin/bash -c ' \
          ${pkgs.${CONTAINERS_BACKEND}}/bin/${CONTAINERS_BACKEND} run \
            --rm \
            --name gitlab-minio \
            --volume ${ENTRYPOINT}:/entrypoint.sh \
            --env ALIAS=$ALIAS \
            --env MINIO_ACCESS_KEY=$MINIO_ACCESS_KEY \
            --env MINIO_SECRET_KEY=$MINIO_SECRET_KEY \
            --entrypoint /entrypoint.sh \
            --cpus 0.03125 \
            --memory-reservation 122m \
            --memory 128m \
            ${MINIO_CLIENT_IMAGE}'
        '';
      };
      wantedBy = [ "${CONTAINERS_BACKEND}-gitlab.service" ];
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
          ];
          environment = let
            REDIS_INSTANCE = (import /etc/nixos/variables.nix).redis_instance;
          in {
            GITLAB_OMNIBUS_CONFIG = ''
              external_url 'http://gitlab.{{ internal_domain_name }}'

              gitlab_rails['smtp_enable'] = false
              gitlab_rails['gitlab_email_enabled'] = false

              gitlab_rails['monitoring_whitelist'] = ['0.0.0.0/0']

              gitlab_rails['object_store']['enabled'] = true
              gitlab_rails['object_store']['connection'] = {
                'provider' => 'AWS',
                'endpoint' => 'http://${toString config.services.minio.listenAddress}',
                'region' => '${toString config.services.minio.region}',
                'path_style' => 'true',
                'aws_access_key_id' => '{{ minio_access_key }}',
                'aws_secret_access_key' => '{{ minio_secret_key }}'
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
                'endpoint' => 'http://${toString config.services.minio.listenAddress}',
                'region' => '${toString config.services.minio.region}',
                'path_style' => 'true',
                'aws_access_key_id' => '{{ minio_access_key }}',
                'aws_secret_access_key' => '{{ minio_secret_key }}'
              }
              gitlab_rails['backup_upload_remote_directory'] = 'gitlab-backup'

              gitlab_rails['initial_root_password'] = '{{ gitlab_password }}'
              gitlab_rails['initial_shared_runners_registration_token'] = '{{ gitlab_token }}'
              gitlab_rails['store_initial_root_password'] = false

              gitlab_rails['db_database'] = 'gitlab'
              gitlab_rails['db_username'] = '{{ postgres_gitlab_database_username }}'
              gitlab_rails['db_password'] = '{{ postgres_gitlab_database_password }}'
              gitlab_rails['db_host'] = '{{ ansible_default_ipv4.address }}'
              gitlab_rails['db_port'] = ${toString config.services.postgresql.port}

              gitlab_rails['redis_host'] = '${toString config.services.redis.servers.${REDIS_INSTANCE}.bind}'
              gitlab_rails['redis_port'] = ${toString config.services.redis.servers.${REDIS_INSTANCE}.port}
              gitlab_rails['redis_password'] = '{{ redis_database_password }}'

              registry_external_url 'http://registry.{{ internal_domain_name }}'
              registry['registry_http_addr'] = '0.0.0.0:5000'
              registry['debug_addr'] = '0.0.0.0:5001'
              registry['storage'] = {
                's3' => {
                  'provider' => 'AWS',
                  'regionendpoint' => 'http://${toString config.services.minio.listenAddress}',
                  'region' => '${toString config.services.minio.region}',
                  'path_style' => 'true',
                  'accesskey' => '{{ minio_access_key }}',
                  'secretkey' => '{{ minio_secret_key }}',
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

              pages_external_url 'http://pages.{{ internal_domain_name }}'
              gitlab_pages['enable'] = true
              gitlab_pages['status_uri'] = '/@status'
              gitlab_pages['listen_proxy'] = '0.0.0.0:8090'
              gitlab_pages['metrics_address'] = '0.0.0.0:9235'

              pages_nginx['enable'] = false
              gitlab_rails['gitlab_kas_enabled'] = false
              gitlab_kas['enable'] = false
              prometheus['enable'] = false

              gitlab_rails['prometheus_address'] = '${toString config.services.prometheus.listenAddress}:${toString config.services.prometheus.port}'

              alertmanager['enable'] = false
              node_exporter['enable'] = false
              redis_exporter['enable'] = false
              postgres_exporter['enable'] = false

              gitlab_exporter['enable'] = true
              gitlab_exporter['listen_address'] = '0.0.0.0'
              gitlab_exporter['listen_port'] = '9168'

              prometheus_monitoring['enable'] = false

              gitaly['prometheus_listen_addr'] = '0.0.0.0:9236'
            '';
          };
          extraOptions = [
            "--shm-size=256m"
            "--cpus=1"
            "--memory-reservation=3891m"
            "--memory=4096m"
          ];
          image = "gitlab/gitlab-ce:15.10.2-ce.0";
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

      virtualHosts."gitlab.{{ internal_domain_name }}" = {
        locations."/" = {
          extraConfig = ''
            access_log /var/log/nginx/gitlab_access.log gitlab_ssl_access;
            error_log  /var/log/nginx/gitlab_error.log;

            client_max_body_size 250m;
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

      virtualHosts."registry.{{ internal_domain_name }}" = {
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

      virtualHosts."pages.{{ internal_domain_name }}" = {
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

  systemd.services = {
    gitlab-1password = {
      after = [
        "${CONTAINERS_BACKEND}-gitlab.service"
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

            op item get 'GitLab (generated)' \
              --vault 'Local server' \
              --session $SESSION_TOKEN > /dev/null

            if [ $? != 0 ]; then
              op item template get Login --session $SESSION_TOKEN | op item create --vault 'Local server' - \
                --title 'GitLab (generated)' \
                --url http://gitlab.$INTERNAL_DOMAIN_NAME \
                username=root \
                password=$GITLAB_PASSWORD \
                'DB connection command'[password]="PGPASSWORD=\"$POSTGRES_GITLAB_DATABASE_PASSWORD\" psql -h {{ ansible_default_ipv4.address }} -p 5432 -U $POSTGRES_GITLAB_DATABASE_USERNAME gitlab" \
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
            GITLAB_PASSWORD = {{ gitlab_password }}
            POSTGRES_GITLAB_DATABASE_PASSWORD = {{ postgres_gitlab_database_password }}
            POSTGRES_GITLAB_DATABASE_USERNAME = {{ postgres_gitlab_database_username }}
          '';
        };
        ExecStart = ''${pkgs.bash}/bin/bash -c ' \
          ${pkgs.${CONTAINERS_BACKEND}}/bin/${CONTAINERS_BACKEND} run \
            --rm \
            --name gitlab-1password \
            --volume ${ENTRYPOINT}:/entrypoint.sh \
            --env OP_DEVICE=$OP_DEVICE \
            --env OP_MASTER_PASSWORD="$OP_MASTER_PASSWORD" \
            --env OP_SUBDOMAIN=$OP_SUBDOMAIN \
            --env OP_EMAIL_ADDRESS=$OP_EMAIL_ADDRESS \
            --env OP_SECRET_KEY=$OP_SECRET_KEY \
            --env INTERNAL_DOMAIN_NAME=$INTERNAL_DOMAIN_NAME \
            --env GITLAB_PASSWORD=$GITLAB_PASSWORD \
            --env POSTGRES_GITLAB_DATABASE_PASSWORD=$POSTGRES_GITLAB_DATABASE_PASSWORD \
            --env POSTGRES_GITLAB_DATABASE_USERNAME=$POSTGRES_GITLAB_DATABASE_USERNAME \
            --entrypoint /entrypoint.sh \
            --cpus 0.01563 \
            --memory-reservation 61m \
            --memory 64m \
            ${ONE_PASSWORD_IMAGE}'
        '';
      };
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
}
