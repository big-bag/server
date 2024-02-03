{ config, lib, pkgs, ... }:

let
  MINIO_BUCKET = "alertmanager";
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
    "alertmanager/minio/envs" = {
      mode = "0400";
      owner = config.users.users.root.name;
      group = config.users.users.root.group;
    };
  };

  systemd.services = {
    alertmanager-minio = {
      before = [ "alertmanager.service" ];
      serviceConfig = {
        Type = "oneshot";
        EnvironmentFile = [
          config.sops.secrets."minio/application/envs".path
          config.sops.secrets."alertmanager/minio/envs".path
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
                --comment alertmanager \
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
      wantedBy = [ "alertmanager.service" ];
    };
  };

  systemd.services = {
    alertmanager = {
      description = "Alertmanager Service Daemon";
      serviceConfig = let
        MINIO_REGION = config.virtualisation.oci-containers.containers.minio.environment.MINIO_REGION;
        config_yml = pkgs.writeTextFile {
          name = "config.yml";
          text = ''
            # Comma-separated list of components to include in the instantiated process. The
            # default value 'all' includes all components that are required to form a
            # functional Grafana Mimir instance in single-binary mode. Use the '-modules'
            # command line flag to get a list of available components, and to see which
            # components are included with 'all'.
            # CLI flag: -target
            target: alertmanager

            # When set to true, incoming HTTP requests must specify tenant ID in HTTP
            # X-Scope-OrgId header. When set to false, tenant ID from -auth.no-auth-tenant
            # is used instead.
            # CLI flag: -auth.multitenancy-enabled
            multitenancy_enabled: false

            # (advanced) Tenant ID to use when multitenancy is disabled.
            # CLI flag: -auth.no-auth-tenant
            no_auth_tenant: anonymous

            api:
              # (advanced) HTTP URL path under which the Alertmanager ui and api will be
              # served.
              # CLI flag: -http.alertmanager-http-prefix
              alertmanager_http_prefix: /alertmanager

            # The server block configures the HTTP and gRPC server of the launched
            # service(s).
            server:
              # HTTP server listen address.
              # CLI flag: -server.http-listen-address
              http_listen_address: ${IP_ADDRESS}

              # HTTP server listen port.
              # CLI flag: -server.http-listen-port
              http_listen_port: 9093

              # gRPC server listen address.
              # CLI flag: -server.grpc-listen-address
              grpc_listen_address: ${IP_ADDRESS}

              # gRPC server listen port.
              # CLI flag: -server.grpc-listen-port
              grpc_listen_port: 9097

              # (advanced) Register the intrumentation handlers (/metrics etc).
              # CLI flag: -server.register-instrumentation
              register_instrumentation: true

              # (advanced) Base path to serve all API routes from (e.g. /v1/)
              # CLI flag: -server.path-prefix
              http_path_prefix: /alertmanager/

            activity_tracker:
              # File where ongoing activities are stored. If empty, activity tracking is
              # disabled.
              # CLI flag: -activity-tracker.filepath
              filepath: ./metrics-activity.log

            # The alertmanager block configures the alertmanager.
            alertmanager:
              # Directory to store Alertmanager state and temporarily configuration files. The
              # content of this directory is not required to be persisted between restarts
              # unless Alertmanager replication has been disabled.
              # CLI flag: -alertmanager.storage.path
              data_dir: ./data-alertmanager/

              # The URL under which Alertmanager is externally reachable (eg. could be
              # different than -http.alertmanager-http-prefix in case Alertmanager is served
              # via a reverse proxy). This setting is used both to configure the internal
              # requests router and to generate links in alert templates. If the external URL
              # has a path portion, it will be used to prefix all HTTP endpoints served by
              # Alertmanager, both the UI and API.
              # CLI flag: -alertmanager.web.external-url
              external_url: https://${DOMAIN_NAME_INTERNAL}/alertmanager/alertmanager

              # (advanced) How frequently to poll Alertmanager configs.
              # CLI flag: -alertmanager.configs.poll-interval
              poll_interval: 30s

              sharding_ring:
                # (advanced) The replication factor to use when sharding the alertmanager.
                # CLI flag: -alertmanager.sharding-ring.replication-factor
                replication_factor: 1

              # (advanced) Enable the alertmanager config API.
              # CLI flag: -alertmanager.enable-api
              enable_api: true

            # The alertmanager_storage block configures the alertmanager storage backend.
            alertmanager_storage:
              # Backend storage to use. Supported backends are: s3, gcs, azure, swift,
              # filesystem, local.
              # CLI flag: -alertmanager-storage.backend
              backend: s3

              # The s3_backend block configures the connection to Amazon S3 object storage
              # backend.
              # The CLI flags prefix for this block configuration is: alertmanager-storage
              s3:
                # The S3 bucket endpoint. It could be an AWS S3 endpoint listed at
                # https://docs.aws.amazon.com/general/latest/gr/s3.html or the address of an
                # S3-compatible service in hostname:port format.
                # CLI flag: -<prefix>.s3.endpoint
                endpoint: ${IP_ADDRESS}:9000

                # S3 region. If unset, the client will issue a S3 GetBucketLocation API call to
                # autodetect it.
                # CLI flag: -<prefix>.s3.region
                region: ${MINIO_REGION}

                # S3 bucket name
                # CLI flag: -<prefix>.s3.bucket-name
                bucket_name: ${MINIO_BUCKET}

                # S3 secret access key
                # CLI flag: -<prefix>.s3.secret-access-key
                secret_access_key: ''${MINIO_SERVICE_ACCOUNT_SECRET_KEY}

                # S3 access key ID
                # CLI flag: -<prefix>.s3.access-key-id
                access_key_id: ''${MINIO_SERVICE_ACCOUNT_ACCESS_KEY}

                # (advanced) If enabled, use http:// for the S3 endpoint instead of https://.
                # This could be useful in local dev/test environments while using an
                # S3-compatible backend storage, like Minio.
                # CLI flag: -<prefix>.s3.insecure
                insecure: true

            # The memberlist block configures the Gossip memberlist.
            memberlist:
              # (advanced) How much space to use for keeping received and sent messages in
              # memory for troubleshooting (two buffers). 0 to disable.
              # CLI flag: -memberlist.message-history-buffer-bytes
              message_history_buffer_bytes: 10240

              # IP address to listen on for gossip messages. Multiple addresses may be
              # specified. Defaults to 0.0.0.0
              # CLI flag: -memberlist.bind-addr
              bind_addr: [ 127.0.0.1 ]

              # Port to listen on for gossip messages.
              # CLI flag: -memberlist.bind-port
              bind_port: 7947

            usage_stats:
              # Enable anonymous usage reporting.
              # CLI flag: -usage-stats.enabled
              enabled: false
          '';
        };
      in {
        Type = "simple";
        EnvironmentFile = config.sops.secrets."alertmanager/minio/envs".path;
        ExecStart = ''
          ${pkgs.mimir}/bin/mimir \
            -config.file=${config_yml} \
            -config.expand-env=true
        '';
        DevicePolicy = "closed";
        DynamicUser = true;
        NoNewPrivileges = true;
        ProtectSystem = "full";
        Restart = "always";
        StateDirectory = "alertmanager";
        WorkingDirectory = "/var/lib/alertmanager";
        CPUQuota = "1%";
        MemoryHigh = "30M";
        MemoryMax = "32M";
      };
      wantedBy = [ "multi-user.target" ];
    };
  };

  networking = {
    firewall = {
      allowedTCPPorts = [ 9093 ];
    };
  };

  sops.secrets = {
    "alertmanager/nginx/file/basic_auth" = {
      mode = "0400";
      owner = config.services.nginx.user;
      group = config.services.nginx.group;
    };
  };

  services = {
    nginx = {
      virtualHosts.${DOMAIN_NAME_INTERNAL} = {
        locations."/alertmanager/" = {
          extraConfig = ''
            if ($ssl_client_verify != "SUCCESS") {
              return 496;
            }
          '';
          proxyPass = "http://${IP_ADDRESS}:9093";
          basicAuthFile = config.sops.secrets."alertmanager/nginx/file/basic_auth".path;
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
    "alertmanager/nginx/envs" = {
      mode = "0400";
      owner = config.users.users.root.name;
      group = config.users.users.root.group;
    };
  };

  systemd.services = {
    alertmanager-1password = {
      after = [ "alertmanager.service" ];
      preStart = "${pkgs.coreutils}/bin/sleep $((RANDOM % ${(import ./variables.nix).one_password_max_delay}))";
      serviceConfig = {
        Type = "oneshot";
        EnvironmentFile = [
          config.sops.secrets."1password/application/envs".path
          config.sops.secrets."alertmanager/nginx/envs".path
          config.sops.secrets."alertmanager/minio/envs".path
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

        ${pkgs._1password}/bin/op item get Alertmanager \
          --vault Server \
          --session $SESSION_TOKEN > /dev/null

        if [ $? != 0 ]
        then
          ${pkgs._1password}/bin/op item template get Login --session $SESSION_TOKEN | ${pkgs._1password}/bin/op item create --vault Server - \
            --title Alertmanager \
            --url https://${DOMAIN_NAME_INTERNAL}/alertmanager \
            username=$NGINX_USERNAME \
            password=$NGINX_PASSWORD \
            MinIO.'Access Key'[text]=$MINIO_SERVICE_ACCOUNT_ACCESS_KEY \
            MinIO.'Secret Key'[password]=$MINIO_SERVICE_ACCOUNT_SECRET_KEY \
            --session $SESSION_TOKEN > /dev/null
          ${pkgs.coreutils}/bin/echo "Item created successfully."
        else
          ${pkgs._1password}/bin/op item edit Alertmanager \
            --vault Server \
            --url https://${DOMAIN_NAME_INTERNAL}/alertmanager \
            username=$NGINX_USERNAME \
            password=$NGINX_PASSWORD \
            MinIO.'Access Key'[text]=$MINIO_SERVICE_ACCOUNT_ACCESS_KEY \
            MinIO.'Secret Key'[password]=$MINIO_SERVICE_ACCOUNT_SECRET_KEY \
            --session $SESSION_TOKEN > /dev/null
          ${pkgs.coreutils}/bin/echo "Item updated successfully."
        fi
      '';
      wantedBy = [ "alertmanager.service" ];
    };
  };

  sops.secrets = {
    "mattermost/application/envs" = {
      mode = "0400";
      owner = config.users.users.root.name;
      group = config.users.users.root.group;
    };
  };

  environment = {
    systemPackages = with pkgs; [
      (pkgs.callPackage derivations/script.nix {
        script_name = "mattermost-channel";
        script_path = [
          pkgs.bash
          pkgs.gawk
          pkgs.jq
        ];
      })
      (pkgs.callPackage derivations/script.nix {
        script_name = "mattermost-webhook";
        script_path = [
          pkgs.bash
          pkgs.gawk
        ];
      })
    ];
  };

  sops.secrets = {
    "telegram/application/envs" = {
      mode = "0400";
      owner = config.users.users.root.name;
      group = config.users.users.root.group;
    };
  };

  systemd.services = {
    alertmanager-configure = let
      CONTAINERS_BACKEND = config.virtualisation.oci-containers.backend;
    in {
      after = [ "alertmanager.service" ];
      serviceConfig = {
        Type = "oneshot";
        EnvironmentFile = [
          config.sops.secrets."mattermost/application/envs".path
          config.sops.secrets."telegram/application/envs".path
        ];
      };
      environment = {
        MATTERMOST_ADDRESS = "${IP_ADDRESS}:8065";
        MATTERMOST_CHANNEL_NAME = "Alertmanager";
        CONTAINERS_BINARY = "${pkgs.${CONTAINERS_BACKEND}}/bin/${CONTAINERS_BACKEND}";
        MATTERMOST_TEAM = lib.strings.stringAsChars (x: if x == "." then "-" else x) DOMAIN_NAME_INTERNAL;
        DOMAIN_NAME_INTERNAL = DOMAIN_NAME_INTERNAL;
        GITLAB_ADDRESS = "${IP_ADDRESS}:8181";
        ALERTMANAGER_ADDRESS = "${IP_ADDRESS}:9093";
      };
      script = let
        config_yml = pkgs.writeTextFile {
          name = "config.yml.template";
          text = ''
            global:
              resolve_timeout: 5m
            route:
              receiver: empty
              continue: false
              routes:
                - receiver: mattermost
                  group_by: [ ... ]
                  continue: true
                  group_wait: 30s
                  group_interval: 5m
                  repeat_interval: 24h
                  mute_time_intervals:
                    - offhours
                    - holidays
                - receiver: telegram
                  group_by: [ ... ]
                  continue: false
                  group_wait: 30s
                  group_interval: 5m
                  repeat_interval: 24h
            receivers:
              - name: mattermost
                webhook_configs:
                  - send_resolved: true
                    url: http://$MATTERMOST_ADDRESS/mattermost/hooks/$MATTERMOST_WEBHOOK_ID
                    http_config:
                      enable_http2: false
                      follow_redirects: false
                    max_alerts: 0
              - name: telegram
                telegram_configs:
                  - send_resolved: true
                    api_url: https://api.telegram.org
                    bot_token: $TELEGRAM_BOT_TOKEN
                    chat_id: $TELEGRAM_CHAT_ID
                    disable_notifications: false
                    parse_mode: HTML
              - name: empty
            time_intervals:
              - name: offhours
                time_intervals:
                  - times:
                      - start_time: 19:00
                        end_time: 23:59
                      - start_time: 00:00
                        end_time: 10:00
                    weekdays: [ monday:friday ]
                    location: ${config.time.timeZone}
              - name: holidays
                time_intervals:
                  - weekdays:
                      - saturday
                      - sunday
                    location: ${config.time.timeZone}
          '';
        };
      in ''
        while ! ${pkgs.curl}/bin/curl --silent --request GET http://$MATTERMOST_ADDRESS/mattermost/api/v4/system/ping |
          ${pkgs.gnugrep}/bin/grep '"status":"OK"'
        do
          ${pkgs.coreutils}/bin/echo "Waiting for Mattermost availability."
          ${pkgs.coreutils}/bin/sleep 1
        done

        export $(
          /run/current-system/sw/bin/mattermost-channel.sh \
            ${pkgs.coreutils}/bin/printenv |
          ${pkgs.gnugrep}/bin/grep --word-regexp MATTERMOST_CHANNEL
        )

        export $(
          /run/current-system/sw/bin/mattermost-webhook.sh \
            ${pkgs.coreutils}/bin/printenv |
          ${pkgs.gnugrep}/bin/grep --word-regexp MATTERMOST_WEBHOOK_ID
        )

        while ! ${pkgs.curl}/bin/curl --silent --request GET http://$ALERTMANAGER_ADDRESS/alertmanager/alertmanager/-/ready |
          ${pkgs.gnugrep}/bin/grep OK
        do
          ${pkgs.coreutils}/bin/echo "Waiting for Alertmanager availability."
          ${pkgs.coreutils}/bin/sleep 1
        done

        ${pkgs.envsubst}/bin/envsubst $MATTERMOST_ADDRESS,$MATTERMOST_WEBHOOK_ID,$TELEGRAM_BOT_TOKEN,$TELEGRAM_CHAT_ID < ${config_yml} > /var/lib/alertmanager/config.yml

        ${pkgs.mimir}/bin/mimirtool alertmanager verify /var/lib/alertmanager/config.yml
        ${pkgs.mimir}/bin/mimirtool alertmanager load /var/lib/alertmanager/config.yml \
          --address=http://$ALERTMANAGER_ADDRESS/alertmanager \
          --id=anonymous
      '';
      wantedBy = [
        "alertmanager.service"
        "multi-user.target"
      ];
    };
  };

  services = {
    grafana-agent = {
      settings = {
        metrics = {
          configs = [{
            name = "alertmanager";
            scrape_configs = [{
              job_name = "local/alertmanager";
              scrape_interval = "1m";
              scrape_timeout = "10s";
              scheme = "http";
              static_configs = [{
                targets = [ "${IP_ADDRESS}:9093" ];
                labels = {
                  cluster = "local";
                  namespace = "local";
                  pod = "mimir";
                };
              }];
              metrics_path = "/alertmanager/metrics";
              follow_redirects = false;
              enable_http2 = false;
            }];
            remote_write = [{
              url = "http://${IP_ADDRESS}:9009/mimir/api/v1/push";
            }];
          }];
        };

        logs = {
          configs = [{
            name = "alertmanager";
            clients = [{
              url = "http://${config.services.loki.configuration.server.http_listen_address}:${toString config.services.loki.configuration.server.http_listen_port}/loki/api/v1/push";
            }];
            positions = {
              filename = "\${STATE_DIRECTORY}/positions/alertmanager.yml";
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
                  regex = "(alertmanager-minio|alertmanager|alertmanager-1password|alertmanager-configure).service";
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
          blackbox = {
            blackbox_config = {
              modules = {
                alertmanager_http_probe = {
                  prober = "http";
                  timeout = "5s";
                  http = {
                    valid_status_codes = [ 200 ];
                    valid_http_versions = [ "HTTP/1.1" ];
                    method = "GET";
                    follow_redirects = false;
                    fail_if_body_not_matches_regexp = [ "OK" ];
                    enable_http2 = false;
                    preferred_ip_protocol = "ip4";
                  };
                };
              };
            };
            blackbox_targets = [
              {
                name = "alertmanager-healthy";
                address = "http://${IP_ADDRESS}:9093/alertmanager/alertmanager/-/healthy";
                module = "alertmanager_http_probe";
              }
              {
                name = "alertmanager-ready";
                address = "http://${IP_ADDRESS}:9093/alertmanager/alertmanager/-/ready";
                module = "alertmanager_http_probe";
              }
            ];
          };
        };
      };
    };
  };
}
