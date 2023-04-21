{ config, ... }:

let
  GITLAB_HOME = "/mnt/ssd/services/gitlab";
  REDIS_INSTANCE = (import /etc/nixos/variables.nix).redis_instance;
in

{
  virtualisation = {
    oci-containers = {
      containers = {
        gitlab = {
          image = "gitlab/gitlab-ce:15.10.2-ce.0";
          autoStart = true;
          extraOptions = [
            "--shm-size=256m"
            "--network=host"
            "--cpus=1"
            "--memory-reservation=3686m"
            "--memory=4096m"
          ];
          volumes = [
            "${GITLAB_HOME}/config:/etc/gitlab"
            "${GITLAB_HOME}/logs:/var/log/gitlab"
            "${GITLAB_HOME}/data:/var/opt/gitlab"
          ];
          environment = {
            GITLAB_OMNIBUS_CONFIG = ''
              external_url 'http://gitlab.{{ internal_domain_name }}'

              gitlab_rails['smtp_enable'] = false
              gitlab_rails['gitlab_email_enabled'] = false

              gitlab_rails['monitoring_whitelist'] = ['127.0.0.1/32']

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
              gitlab_rails['db_host'] = '127.0.0.1'
              gitlab_rails['db_port'] = ${toString config.services.postgresql.port}

              gitlab_rails['redis_host'] = '127.0.0.1'
              gitlab_rails['redis_port'] = ${toString config.services.redis.servers.${REDIS_INSTANCE}.port}
              gitlab_rails['redis_password'] = '{{ redis_database_password }}'

              registry_external_url 'http://registry.{{ internal_domain_name }}'
              registry['registry_http_addr'] = '127.0.0.1:5000'
              registry['debug_addr'] = 'localhost:5001'
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
              gitlab_workhorse['listen_addr'] = '127.0.0.1:8181'
              gitlab_workhorse['prometheus_listen_addr'] = '127.0.0.1:9229'
              gitlab_workhorse['image_scaler_max_procs'] = 1

              puma['listen'] = '127.0.0.1'
              puma['port'] = 8080
              puma['exporter_enabled'] = true
              puma['exporter_address'] = '127.0.0.1'
              puma['exporter_port'] = 8083

              sidekiq['listen_address'] = '127.0.0.1'
              sidekiq['listen_port'] = 8082
              sidekiq['health_checks_listen_address'] = '127.0.0.1'
              sidekiq['health_checks_listen_port'] = 8092

              postgresql['enable'] = false
              redis['enable'] = false
              nginx['enable'] = false

              pages_external_url 'http://pages.{{ internal_domain_name }}'
              gitlab_pages['enable'] = true
              gitlab_pages['status_uri'] = '/@status'
              gitlab_pages['listen_proxy'] = '127.0.0.1:8090'
              gitlab_pages['metrics_address'] = '127.0.0.1:9235'

              pages_nginx['enable'] = false
              gitlab_rails['gitlab_kas_enabled'] = false
              gitlab_kas['enable'] = false
              prometheus['enable'] = false

              gitlab_rails['prometheus_address'] = '127.0.0.1:${toString config.services.prometheus.port}'

              alertmanager['enable'] = false
              node_exporter['enable'] = false
              redis_exporter['enable'] = false
              postgres_exporter['enable'] = false

              gitlab_exporter['enable'] = true
              gitlab_exporter['listen_address'] = '127.0.0.1'
              gitlab_exporter['listen_port'] = '9168'

              prometheus_monitoring['enable'] = false

              gitaly['prometheus_listen_addr'] = '127.0.0.1:9236'
            '';
          };
        };

        op-gitlab = {
          image = "1password/op:2.16.1";
          autoStart = true;
          extraOptions = [
            "--cpus=0.01563"
            "--memory-reservation=58m"
            "--memory=64m"
          ];
          environment = { OP_DEVICE = "{{ hostvars['localhost']['vault_1password_device_id'] }}"; };
          entrypoint = "/bin/bash";
          cmd = [
            "-c" "
              SESSION_TOKEN=$(echo {{ hostvars['localhost']['vault_1password_master_password'] }} | op account add \\
                --address {{ hostvars['localhost']['vault_1password_subdomain'] }}.1password.com \\
                --email {{ hostvars['localhost']['vault_1password_email_address'] }} \\
                --secret-key {{ hostvars['localhost']['vault_1password_secret_key'] }} \\
                --signin --raw)

              op item get 'GitLab (generated)' \\
                --vault 'Local server' \\
                --session $SESSION_TOKEN

              if [ $? != 0 ]; then
                op item template get Login --session $SESSION_TOKEN | op item create --vault 'Local server' - \\
                  --title 'GitLab (generated)' \\
                  --url http://gitlab.{{ internal_domain_name }} \\
                  username=root \\
                  password='{{ gitlab_password }}' \\
                  'DB connection command'[password]='PGPASSWORD=\"{{ postgres_gitlab_database_password }}\" psql -h 127.0.0.1 -p 5432 -U {{ postgres_gitlab_database_username }} gitlab' \\
                  --session $SESSION_TOKEN
              fi
            "
          ];
        };
      };
    };
  };

  systemd = {
    services = {
      podman-op-gitlab = {
        serviceConfig = {
          RestartPreventExitStatus = 0;
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
