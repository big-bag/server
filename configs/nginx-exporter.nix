{ config, pkgs, ... }:

{
  environment.systemPackages = with pkgs; [
    (pkgs.callPackage derivations/nginx-prometheus-exporter.nix {})
  ];

  systemd = {
    services = {
      nginx-exporter = {
        after = [ "nginx.service" ];
        before = [ "grafana-agent.service" ];
        serviceConfig = {
          Type = "simple";
          ExecStart = ''/run/current-system/sw/bin/nginx-prometheus-exporter \
            -nginx.retries=12 \
            -nginx.retry-interval=5s \
            -nginx.scrape-uri=http://127.0.0.1/nginx_status \
            -nginx.timeout=1m \
            -web.listen-address=127.0.0.1:9113 \
            -web.telemetry-path=/metrics
          '';
          Restart = "always";
        };
        wantedBy = [
          "nginx.service"
          "grafana-agent.service"
          "multi-user.target"
        ];
      };
    };
  };

  users.groups.nginx.members = [ "grafana-agent" ];

  services = {
    grafana-agent = {
      settings = {
        metrics = {
          configs = [{
            name = "nginx";
            scrape_configs = [{
              job_name = "nginx";
              scrape_interval = "1m";
              scrape_timeout = "10s";
              scheme = "http";
              static_configs = [{
                targets = [ "127.0.0.1:9113" ];
              }];
              metrics_path = "/metrics";
            }];
            remote_write = let
              IP_ADDRESS = (import ./connection-parameters.nix).ip_address;
            in [{
              url = "http://${IP_ADDRESS}:9009/mimir/api/v1/push";
            }];
          }];
        };

        logs = {
          configs = [{
            name = "nginx";
            clients = [{
              url = "http://${config.services.loki.configuration.server.http_listen_address}:${toString config.services.loki.configuration.server.http_listen_port}/loki/api/v1/push";
            }];
            positions = {
              filename = "/var/lib/private/grafana-agent/positions/nginx.yml";
            };
            scrape_configs = [
              {
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
                    regex = "(nginx-prepare|nginx|nginx-exporter).service";
                    action = "keep";
                  }
                  {
                    source_labels = [ "__journal__systemd_unit" ];
                    target_label = "systemd_unit";
                    action = "replace";
                  }
                ];
              }
              {
                job_name = "nginx";
                static_configs = [{
                  targets = [
                    "localhost"
                  ];
                  labels = {
                    __path__ = "/var/log/nginx/access*.log";
                  };
                }];
                pipeline_stages = [
                  {
                    regex = {
                      # parse logs which look like:
                      # 192.168.0.1 - - [06/Dec/2023:18:19:51 +0300] "POST /mattermost/api/v4/users/status/ids HTTP/2.0" 200 127 "-" "Mozilla/5.0 (Macintosh; Intel Mac OS X 10.15; rv:121.0) Gecko/20100101 Firefox/121.0"
                      # 192.168.0.1 - - [06/Dec/2023:21:12:24 +0300] "GET /grafana/public/img/fav32.png HTTP/2.0" 499 0 "https://domain.com/grafana/explore?panes=%7B%22-0b%22:%7B%22datasource%22:%22P8E80F9AEF21F6940%22,%22queries%22:%5B%7B%22refId%22:%22A%22,%22expr%22:%22%7Bfilename%3D%5C%22%2Fvar%2Flog%2Fnginx%2Faccess.log%5C%22%7D%20%7C%3D%20%60%60%22,%22queryType%22:%22range%22,%22datasource%22:%7B%22type%22:%22loki%22,%22uid%22:%22P8E80F9AEF21F6940%22%7D,%22editorMode%22:%22builder%22%7D%5D,%22range%22:%7B%22from%22:%22now-5m%22,%22to%22:%22now%22%7D%7D%7D&schemaVersion=1&orgId=1" "Mozilla/5.0 (Macintosh; Intel Mac OS X 10.15; rv:121.0) Gecko/20100101 Firefox/121.0"
                      # 192.168.0.1 - - [07/Dec/2023:12:34:58 +0300] "GET /grafana/public/fonts/roboto/L0xTDF4xlVMF-BfR8bXMIhJHg45mwgGEFl0_3vrtSM1J-gEPT5Ese6hmHSh0mQ.woff2 HTTP/2.0" 304 0 "https://enterprise.internal/grafana/public/build/grafana.light.bbe69ddb3979b7904078.css" "Mozilla/5.0 (Macintosh; Intel Mac OS X 10.15; rv:121.0) Gecko/20100101 Firefox/121.0"
                      expression = ''^(?P<nginx_remote_addr>[0-9.]+)\s-\s(?P<nginx_remote_user>[^.*]+)\s\[(?P<nginx_time_local>[0-9\/a-zA-Z:\s+]+)]\s"(?P<nginx_request_method>[A-Z]+)\s(?P<nginx_request_path>[\/a-zA-Z0-9]+)[^\s\s$]{0,}\s(?P<nginx_request_protocol>[A-Z\/0-9.]+)"\s(?P<nginx_status>[0-9]+)\s(?P<nginx_bytes_sent>[0-9]+)\s"(?P<nginx_http_referer>[a-z0-9:\/.-]+)[^\s\s$]{0,}\s"(?P<nginx_http_user_agent>[^"]+)"$'';
                    };
                  }
                  {
                    timestamp = {
                      source = "nginx_time_local";
                      format = "02/Jan/2006:15:04:05 -0700";
                      location = "Europe/Moscow";
                      action_on_failure = "fudge";
                    };
                  }
                  {
                    labels = {
                      nginx_remote_addr = "nginx_remote_addr";
                      nginx_remote_user = "nginx_remote_user";
                      nginx_request_method = "nginx_request_method";
                      nginx_request_path = "nginx_request_path";
                      nginx_request_protocol = "nginx_request_protocol";
                      nginx_status = "nginx_status";
                      nginx_http_referer = "nginx_http_referer";
                      nginx_http_user_agent = "nginx_http_user_agent";
                    };
                  }
                  {
                    regex = {
                      source = "filename";
                      expression = ''\/var\/log\/nginx\/(?P<nginx_log_file>access.*log)'';
                    };
                  }
                  {
                    labels = {
                      nginx_log_file = "nginx_log_file";
                    };
                  }
                  {
                    labeldrop = [
                      "filename"
                    ];
                  }
                ];
              }
            ];
          }];
        };
      };
    };
  };
}
