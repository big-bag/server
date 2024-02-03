{ config, lib, pkgs, ... }:

let
  IP_ADDRESS = (import ./connection-parameters.nix).ip_address;
  MINIO_REGION = config.virtualisation.oci-containers.containers.minio.environment.MINIO_REGION;
  DOMAIN_NAME_INTERNAL = (import ./connection-parameters.nix).domain_name_internal;
in

{
  systemd.services = {
    mimir-prepare = {
      before = [ "var-lib-private-mimir.mount" ];
      serviceConfig = {
        Type = "oneshot";
      };
      script = "${pkgs.coreutils}/bin/mkdir -p /mnt/ssd/monitoring";
      wantedBy = [ "var-lib-private-mimir.mount" ];
    };
  };

  fileSystems."/var/lib/private/mimir" = {
    device = "/mnt/ssd/monitoring/mimir";
    options = [
      "bind"
      "x-systemd.before=mimir.service"
      "x-systemd.wanted-by=mimir.service"
    ];
  };

  sops.secrets = {
    "minio/application/envs" = {
      mode = "0400";
      owner = config.users.users.root.name;
      group = config.users.users.root.group;
    };
  };

  sops.secrets = {
    "mimir/minio/envs" = {
      mode = "0400";
      owner = config.users.users.root.name;
      group = config.users.users.root.group;
    };
  };

  systemd.services = {
    mimir-minio = {
      before = [ "mimir.service" ];
      serviceConfig = {
        Type = "oneshot";
        EnvironmentFile = [
          config.sops.secrets."minio/application/envs".path
          config.sops.secrets."mimir/minio/envs".path
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
                        "Resource": [
                            "arn:aws:s3:::mimir-blocks",
                            "arn:aws:s3:::mimir-ruler"
                        ]
                    },
                    {
                        "Effect": "Allow",
                        "Action": [
                            "s3:PutObject",
                            "s3:GetObject",
                            "s3:DeleteObject"
                        ],
                        "Resource": [
                            "arn:aws:s3:::mimir-blocks/*",
                            "arn:aws:s3:::mimir-ruler/*"
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

            ${pkgs.minio-client}/bin/mc mb --ignore-existing $ALIAS/mimir-blocks
            ${pkgs.minio-client}/bin/mc mb --ignore-existing $ALIAS/mimir-ruler

            ${pkgs.minio-client}/bin/mc admin user svcacct info $ALIAS $MINIO_SERVICE_ACCOUNT_ACCESS_KEY

            if [ $? != 0 ]
            then
              ${pkgs.minio-client}/bin/mc admin user svcacct add \
                --access-key $MINIO_SERVICE_ACCOUNT_ACCESS_KEY \
                --secret-key $MINIO_SERVICE_ACCOUNT_SECRET_KEY \
                --policy ${policy_json} \
                --comment mimir \
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
      wantedBy = [ "mimir.service" ];
    };
  };

  services = {
    mimir = let
      config_yml = pkgs.writeTextFile {
        name = "config.yml";
        text = ''
          # Comma-separated list of components to include in the instantiated process. The
          # default value 'all' includes all components that are required to form a
          # functional Grafana Mimir instance in single-binary mode. Use the '-modules'
          # command line flag to get a list of available components, and to see which
          # components are included with 'all'.
          # CLI flag: -target
          target: all

          # When set to true, incoming HTTP requests must specify tenant ID in HTTP
          # X-Scope-OrgId header. When set to false, tenant ID from -auth.no-auth-tenant
          # is used instead.
          # CLI flag: -auth.multitenancy-enabled
          multitenancy_enabled: false

          # (advanced) Tenant ID to use when multitenancy is disabled.
          # CLI flag: -auth.no-auth-tenant
          no_auth_tenant: anonymous

          # The server block configures the HTTP and gRPC server of the launched
          # service(s).
          server:
            # HTTP server listen address.
            # CLI flag: -server.http-listen-address
            http_listen_address: ${IP_ADDRESS}

            # HTTP server listen port.
            # CLI flag: -server.http-listen-port
            http_listen_port: 9009

            # gRPC server listen address.
            # CLI flag: -server.grpc-listen-address
            grpc_listen_address: 127.0.0.1

            # gRPC server listen port.
            # CLI flag: -server.grpc-listen-port
            grpc_listen_port: 9095

            # (advanced) Register the intrumentation handlers (/metrics etc).
            # CLI flag: -server.register-instrumentation
            register_instrumentation: true

            # (advanced) Limit on the size of a gRPC message this server can receive
            # (bytes).
            # CLI flag: -server.grpc-max-recv-msg-size-bytes
            grpc_server_max_recv_msg_size: 104857600

            # (advanced) Limit on the size of a gRPC message this server can send (bytes).
            # CLI flag: -server.grpc-max-send-msg-size-bytes
            grpc_server_max_send_msg_size: 104857600

            # (advanced) Base path to serve all API routes from (e.g. /v1/)
            # CLI flag: -server.path-prefix
            http_path_prefix: /mimir/

          # The ingester block configures the ingester.
          ingester:
            ring:
              # Number of ingesters that each time series is replicated to. This option
              # needs be set on ingesters, distributors, queriers and rulers when running in
              # microservices mode.
              # CLI flag: -ingester.ring.replication-factor
              replication_factor: 1

              # (advanced) IP address to advertise in the ring. Default is auto-detected.
              # CLI flag: -ingester.ring.instance-addr
              instance_addr: 127.0.0.1

          # The blocks_storage block configures the blocks storage.
          blocks_storage:
            # The s3_backend block configures the connection to Amazon S3 object storage
            # backend.
            # The CLI flags prefix for this block configuration is: blocks-storage
            s3:
              # S3 bucket name
              # CLI flag: -<prefix>.s3.bucket-name
              bucket_name: mimir-blocks

            # This configures how the querier and store-gateway discover and synchronize
            # blocks stored in the bucket.
            bucket_store:
              # Directory to store synchronized TSDB index headers. This directory is not
              # required to be persisted between restarts, but it's highly recommended in
              # order to improve the store-gateway startup time.
              # CLI flag: -blocks-storage.bucket-store.sync-dir
              sync_dir: ./tsdb-sync/

            tsdb:
              # Directory to store TSDBs (including WAL) in the ingesters. This directory is
              # required to be persisted between restarts.
              # CLI flag: -blocks-storage.tsdb.dir
              dir: ./tsdb/

          # The compactor block configures the compactor component.
          compactor:
            # Directory to temporarily store blocks during compaction. This directory is not
            # required to be persisted between restarts.
            # CLI flag: -compactor.data-dir
            data_dir: ./data-compactor/

          # The store_gateway block configures the store-gateway component.
          store_gateway:
            # The hash ring configuration.
            sharding_ring:
              # (advanced) The replication factor to use when sharding blocks. This option
              # needs be set both on the store-gateway, querier and ruler when running in
              # microservices mode.
              # CLI flag: -store-gateway.sharding-ring.replication-factor
              replication_factor: 1

              # (advanced) IP address to advertise in the ring. Default is auto-detected.
              # CLI flag: -store-gateway.sharding-ring.instance-addr
              instance_addr: 127.0.0.1

          activity_tracker:
            # File where ongoing activities are stored. If empty, activity tracking is
            # disabled.
            # CLI flag: -activity-tracker.filepath
            filepath: ./metrics-activity.log

          # The ruler block configures the ruler.
          ruler:
            # Directory to store temporary rule files loaded by the Prometheus rule
            # managers. This directory is not required to be persisted between restarts.
            # CLI flag: -ruler.rule-path
            rule_path: ./data-ruler/

            # Comma-separated list of URL(s) of the Alertmanager(s) to send notifications
            # to. Each URL is treated as a separate group. Multiple Alertmanagers in HA per
            # group can be supported by using DNS service discovery format, comprehensive of
            # the scheme. Basic auth is supported as part of the URL.
            # CLI flag: -ruler.alertmanager-url
            alertmanager_url: http://127.0.0.1:9093/alertmanager/alertmanager

          # The ruler_storage block configures the ruler storage backend.
          ruler_storage:
            # The s3_backend block configures the connection to Amazon S3 object storage
            # backend.
            # The CLI flags prefix for this block configuration is: ruler-storage
            s3:
              # S3 bucket name
              # CLI flag: -<prefix>.s3.bucket-name
              bucket_name: mimir-ruler

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
            bind_port: 7946

          usage_stats:
            # Enable anonymous usage reporting.
            # CLI flag: -usage-stats.enabled
            enabled: false

          # The common block holds configurations that configure multiple components at a
          # time.
          common:
            storage:
              # Backend storage to use. Supported backends are: s3, gcs, azure, swift,
              # filesystem.
              # CLI flag: -common.storage.backend
              backend: s3

              # The s3_backend block configures the connection to Amazon S3 object storage
              # backend.
              # The CLI flags prefix for this block configuration is: common.storage
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
        '';
      };
    in {
      enable = true;
      configFile = "${config_yml}";
    };
  };

  systemd.services = {
    mimir = {
      serviceConfig = {
        EnvironmentFile = config.sops.secrets."mimir/minio/envs".path;
        ExecStart = pkgs.lib.mkForce ''
          ${pkgs.mimir}/bin/mimir \
            -config.file=${config.services.mimir.configFile} \
            -config.expand-env=true
        '';
        StartLimitBurst = 0;
        CPUQuota = "6%";
        MemoryHigh = "1946M";
        MemoryMax = "2048M";
      };
    };
  };

  networking = {
    firewall = {
      allowedTCPPorts = [ 9009 ];
    };
  };

  sops.secrets = {
    "mimir/nginx/file/basic_auth" = {
      mode = "0400";
      owner = config.services.nginx.user;
      group = config.services.nginx.group;
    };
  };

  services = {
    nginx = {
      virtualHosts.${DOMAIN_NAME_INTERNAL} = {
        locations."/mimir/" = {
          extraConfig = ''
            if ($ssl_client_verify != "SUCCESS") {
              return 496;
            }
          '';
          proxyPass = "http://${IP_ADDRESS}:9009";
          basicAuthFile = config.sops.secrets."mimir/nginx/file/basic_auth".path;
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
    "mimir/nginx/envs" = {
      mode = "0400";
      owner = config.users.users.root.name;
      group = config.users.users.root.group;
    };
  };

  systemd.services = {
    mimir-1password = {
      after = [ "mimir.service" ];
      preStart = "${pkgs.coreutils}/bin/sleep $((RANDOM % ${(import ./variables.nix).one_password_max_delay}))";
      serviceConfig = {
        Type = "oneshot";
        EnvironmentFile = [
          config.sops.secrets."1password/application/envs".path
          config.sops.secrets."mimir/nginx/envs".path
          config.sops.secrets."mimir/minio/envs".path
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

        ${pkgs._1password}/bin/op item get Mimir \
          --vault Server \
          --session $SESSION_TOKEN > /dev/null

        if [ $? != 0 ]
        then
          ${pkgs._1password}/bin/op item template get Database --session $SESSION_TOKEN | ${pkgs._1password}/bin/op item create --vault Server - \
            --title Mimir \
            website[url]=https://${DOMAIN_NAME_INTERNAL}/mimir \
            username=$NGINX_USERNAME \
            password=$NGINX_PASSWORD \
            MinIO.'Access Key'[text]=$MINIO_SERVICE_ACCOUNT_ACCESS_KEY \
            MinIO.'Secret Key'[password]=$MINIO_SERVICE_ACCOUNT_SECRET_KEY \
            --session $SESSION_TOKEN > /dev/null
          ${pkgs.coreutils}/bin/echo "Item created successfully."
        else
          ${pkgs._1password}/bin/op item edit Mimir \
            --vault Server \
            website[url]=https://${DOMAIN_NAME_INTERNAL}/mimir \
            username=$NGINX_USERNAME \
            password=$NGINX_PASSWORD \
            MinIO.'Access Key'[text]=$MINIO_SERVICE_ACCOUNT_ACCESS_KEY \
            MinIO.'Secret Key'[password]=$MINIO_SERVICE_ACCOUNT_SECRET_KEY \
            --session $SESSION_TOKEN > /dev/null
          ${pkgs.coreutils}/bin/echo "Item updated successfully."
        fi
      '';
      wantedBy = [ "mimir.service" ];
    };
  };
}
