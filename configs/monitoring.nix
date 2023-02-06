{ config, pkgs, ... }:

{
  fileSystems."/var/lib/prometheus2" = {
    device = "/mnt/ssd/monitoring/prometheus2";
    options = [ "bind" ];
  };

  services = {
    prometheus = {
      enable = true;
      listenAddress = "127.0.0.1";
      port = 9090;
      webExternalUrl = "http://{{ hostvars['localhost']['internal_domain_name']['stdout'] }}/prometheus";
      stateDir = "prometheus2";
      retentionTime = "15d";
      checkConfig = "syntax-only";
      enableReload = true;
      globalConfig = {
        scrape_interval = "1m";
        scrape_timeout = "10s";
        evaluation_interval = "1m";
      };
      exporters = {
        node = {
          enable = true;
          listenAddress = "127.0.0.1";
          port = 9100;
          user = "node-exporter";
          group = "node-exporter";
          enabledCollectors = [
            "systemd"
          ];
        };
      };
      scrapeConfigs = [
        {
          job_name = "prometheus";
          scheme = "http";
          static_configs = [{
            targets = [ "127.0.0.1:${toString config.services.prometheus.port}" ];
          }];
          metrics_path = "/prometheus/metrics";
        }
        {
          job_name = "node";
          scheme = "http";
          static_configs = [{
            targets = [ "127.0.0.1:${toString config.services.prometheus.exporters.node.port}" ];
          }];
          metrics_path = "/metrics";
          scrape_interval = "2s";
        }
        {
          job_name = "minio-job";
          scheme = "http";
          static_configs = [{
            targets = [ "${toString config.services.minio.listenAddress}" ];
          }];
          metrics_path = "/minio/v2/metrics/cluster";
          bearer_token_file = "/mnt/ssd/storages/.minioScrapeBearerToken";
        }
        {
          job_name = "grafana";
          scheme = "http";
          static_configs = [{
            targets = [ "127.0.0.1:${toString config.services.grafana.settings.server.http_port}" ];
          }];
          metrics_path = "/metrics";
        }
      ];
    };
  };

  services = {
    minio = {
      enable = true;
      listenAddress = "127.0.0.1:9000";
      consoleAddress = "127.0.0.1:9001";
      dataDir = [ "/mnt/ssd/storages/minio/data" ];
      configDir = "/mnt/ssd/storages/minio/config";
      region = "eu-west-3";
      browser = true;
      rootCredentialsFile = "/mnt/ssd/storages/.minioEnvironmentVariables";
    };
  };

  virtualisation.oci-containers.containers = {
    minio-client = {
      image = "minio/mc:RELEASE.2023-01-11T03-14-16Z";
      autoStart = true;
      extraOptions = [ "--network=host" ];
      volumes = [ "/mnt/ssd/storages/.minioScrapeBearerToken:/mnt/.minioScrapeBearerToken" ];
      environment = { ALIAS = "local"; };
      entrypoint = "/bin/sh";
      cmd = [
        "-c" "
          mc alias set $ALIAS http://${toString config.services.minio.listenAddress} {{ minio_access_key }} {{ minio_secret_key }}
          mc admin prometheus generate $ALIAS | grep bearer_token | awk '{ print $2 }' | tr -d '\n' > /mnt/.minioScrapeBearerToken

          mc mb --ignore-existing $ALIAS/loki
          mc anonymous set public $ALIAS/loki

          mc mb --ignore-existing $ALIAS/mimir-blocks
          mc anonymous set public $ALIAS/mimir-blocks

          mc mb --ignore-existing $ALIAS/mimir-ruler
          mc anonymous set public $ALIAS/mimir-ruler

          mc mb --ignore-existing $ALIAS/mimir-alertmanager
          mc anonymous set public $ALIAS/mimir-alertmanager
        "
      ];
    };
  };

  fileSystems."/var/lib/private/mimir" = {
    device = "/mnt/ssd/monitoring/mimir";
    options = [
      "bind"
      "x-systemd.before=mimir.service"
    ];
  };

  services = {
    mimir = {
      enable = true;
      configuration = {
        multitenancy_enabled = false;
        server = {
          http_listen_address = "127.0.0.1";
          http_listen_port = 9009;
          grpc_listen_address = "127.0.0.1";
          grpc_listen_port = 9095;
          http_path_prefix = "/mimir/";
        };
        ingester = {
          ring = {
            replication_factor = 1;
            instance_addr = "127.0.0.1";
          };
        };
        blocks_storage = {
          s3 = {
            bucket_name = "mimir-blocks";
          };
          bucket_store = {
            sync_dir = "./tsdb-sync/";
          };
          tsdb = {
            dir = "./tsdb/";
          };
        };
        compactor = {
          data_dir = "./data-compactor/";
        };
        store_gateway = {
          sharding_ring = {
            replication_factor = 1;
          };
        };
        activity_tracker = {
          filepath = "./metrics-activity.log";
        };
        ruler = {
          rule_path = "./data-ruler/";
        };
        ruler_storage = {
          s3 = {
            bucket_name = "mimir-ruler";
          };
        };
        alertmanager = {
          data_dir = "./data-alertmanager/";
          sharding_ring = {
            replication_factor = 1;
          };
        };
        alertmanager_storage = {
          s3 = {
            bucket_name = "mimir-alertmanager";
          };
        };
        memberlist = {
          message_history_buffer_bytes = 10240;
          bind_addr = ["127.0.0.1"];
        };
        common = {
          storage = {
            backend = "s3";
            s3 = {
              endpoint = "${toString config.services.minio.listenAddress}";
              region = "${toString config.services.minio.region}";
              secret_access_key = "{{ minio_secret_key }}";
              access_key_id = "{{ minio_access_key }}";
              insecure = true;
              http = {
                insecure_skip_verify = true;
              };
            };
          };
        };
      };
    };

    loki = {
      enable = true;
      dataDir = "/mnt/ssd/monitoring/loki";
      user = "loki";
      group = "loki";
      extraFlags = [
        "-log-config-reverse-order"
      ];
      configuration = {
        auth_enabled = false;
        server = {
          http_listen_address = "127.0.0.1";
          http_listen_port = 3100;
          grpc_listen_address = "0.0.0.0";
          grpc_listen_port = 9096;
        };
        ingester = {
          lifecycler = {
            ring = {
              kvstore = {
                store = "inmemory";
              };
              replication_factor = 1;
            };
            final_sleep = "0s";
          };
          chunk_retain_period = "30s";
          chunk_idle_period = "5m";
          wal = {
            dir = "${config.services.loki.dataDir}/wal";
          };
        };
        storage_config = {
          boltdb = {
            directory = "${config.services.loki.dataDir}/index";
          };
          filesystem = {
            directory = "${config.services.loki.dataDir}/chunks";
          };
          aws = {
            s3forcepathstyle = true;
            bucketnames = "loki";
            endpoint = "http://${toString config.services.minio.listenAddress}";
            region = "${toString config.services.minio.region}";
            access_key_id = "{{ minio_access_key }}";
            secret_access_key = "{{ minio_secret_key }}";
            insecure = true;
            http_config = {
              insecure_skip_verify = true;
            };
          };
          boltdb_shipper = {
            active_index_directory = "${config.services.loki.dataDir}/index";
            shared_store = "s3";
            cache_location = "${config.services.loki.dataDir}/cache";
            resync_interval = "5s";
          };
        };
        schema_config = {
          configs = [
            {
              from = "2023-01-14";
              store = "boltdb";
              object_store = "filesystem";
              schema = "v11";
              index = {
                prefix = "index_";
                period = "168h";
              };
            }
            {
              from = "2023-01-29";
              store = "boltdb-shipper";
              object_store = "aws";
              schema = "v11";
              index = {
                prefix = "index_";
                period = "24h";
              };
            }
          ];
        };
        compactor = {
          working_directory = "${config.services.loki.dataDir}/compactor";
          shared_store = "s3";
        };
        limits_config = {
          enforce_metric_name = false;
        };
      };
    };

    promtail = {
      enable = true;
      extraFlags = [
        "-log-config-reverse-order"
      ];
      configuration = {
        server = {
          disable = false;
          http_listen_address = "127.0.0.1";
          http_listen_port = 9080;
          grpc_listen_address = "127.0.0.1";
          grpc_listen_port = 9097;
        };
        clients = [{
          url = "http://127.0.0.1:${toString config.services.loki.configuration.server.http_listen_port}/loki/api/v1/push";
        }];
        positions = {
          filename = "/mnt/ssd/monitoring/promtail/positions.yaml";
        };
        scrape_configs = [
          {
            job_name = "journal";
            journal = {
              json = false;
              max_age = "12h";
              labels = {
                job = "systemd-journal";
              };
              path = "/var/log/journal";
            };
            relabel_configs = [{
              source_labels = ["__journal__systemd_unit"];
              target_label = "unit";
            }];
          }
        ];
      };
    };

    grafana = {
      enable = true;
      dataDir = "/mnt/ssd/monitoring/grafana";
      settings = {
        server = {
          protocol = "http";
          http_addr = "127.0.0.1";
          http_port = 3000;
          domain = "{{ hostvars['localhost']['internal_domain_name']['stdout'] }}";
          root_url = "%(protocol)s://%(domain)s:%(http_port)s/grafana/";
          enable_gzip = true;
        };
        security = {
          admin_user = "{{ grafana_auth_user }}";
          admin_password = "$__file{/mnt/ssd/monitoring/.grafanaAdminPassword}";
        };
        database = {
          type = "sqlite3";
          path = "${config.services.grafana.dataDir}/data/grafana.db";
        };
        analytics.reporting_enabled = false;
      };
      provision = {
        enable = true;
        datasources.path = pkgs.writeText "datasources.yml" ''
          apiVersion: 1

          datasources:
            - name: Prometheus
              type: prometheus
              access: proxy
              orgId: 1
              uid: {{ prometheus_datasource_uid }}
              url: http://127.0.0.1:${toString config.services.prometheus.port}/prometheus
              isDefault: false
              jsonData:
                manageAlerts: true
                timeInterval: ${toString config.services.prometheus.globalConfig.scrape_interval} # 'Scrape interval' in Grafana UI, defaults to 15s
                httpMethod: POST
                prometheusType: Prometheus
              editable: true

            - name: Mimir
              type: prometheus
              access: proxy
              orgId: 1
              uid: {{ mimir_datasource_uid }}
              url: http://127.0.0.1:${toString config.services.mimir.configuration.server.http_listen_port}/mimir/prometheus
              isDefault: false
              jsonData:
                manageAlerts: true
                timeInterval: 1m # 'Scrape interval' in Grafana UI, defaults to 15s
                httpMethod: POST
                prometheusType: Mimir
              editable: true

            - name: Loki
              type: loki
              access: proxy
              orgId: 1
              uid: {{ loki_datasource_uid }}
              url: http://127.0.0.1:${toString config.services.loki.configuration.server.http_listen_port}
              isDefault: true
              jsonData:
                manageAlerts: true
                maxLines: 1000
              editable: true
        '';
        dashboards.path = pkgs.writeText "dashboards.yml" ''
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

    nginx = {
      upstreams."grafana" = {
        servers = { "127.0.0.1:${toString config.services.grafana.settings.server.http_port}" = {}; };
      };

      virtualHosts."{{ hostvars['localhost']['internal_domain_name']['stdout'] }}" = {
        locations."/prometheus" = {
          proxyPass     = "http://127.0.0.1:${toString config.services.prometheus.port}";
          basicAuthFile = /mnt/ssd/monitoring/.prometheusBasicAuthPassword;
        };

        locations."/minio" = {
          extraConfig = ''
            rewrite ^/minio/(.*) /$1 break;
            proxy_set_header Host $host;

            # Proxy Minio WebSocket connections.
            proxy_http_version 1.1;
            proxy_set_header Upgrade    $http_upgrade;
            proxy_set_header Connection $connection_upgrade;
          '';
          proxyPass = "http://${toString config.services.minio.consoleAddress}";
        };

        locations."/mimir/" = {
          proxyPass     = "http://127.0.0.1:${toString config.services.mimir.configuration.server.http_listen_port}";
          basicAuthFile = /mnt/ssd/monitoring/.mimirBasicAuthPassword;
        };

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

            proxy_set_header Upgrade    $http_upgrade;
            proxy_set_header Connection $connection_upgrade;
            proxy_set_header Host       $host;
          '';
          proxyPass = "http://grafana";
        };
      };
    };
  };
}
