{ config, pkgs, lib, ... }:

let
  MINIO_ENDPOINT = config.services.minio.listenAddress;
  CONTAINERS_BACKEND = config.virtualisation.oci-containers.backend;
  DOMAIN_NAME_INTERNAL = (import ./connection-parameters.nix).domain_name_internal;
in

{
  systemd.services = {
    prometheus-prepare = {
      before = [
        "var-lib-prometheus2.mount"
        "prometheus-minio.service"
      ];
      serviceConfig = {
        Type = "oneshot";
      };
      script = ''
        ${pkgs.coreutils}/bin/mkdir -p /mnt/ssd/monitoring

        # create an empty file for minio bearer token
        if ! [ -f /mnt/ssd/monitoring/.minioScrapeBearerToken ]; then
          ${pkgs.coreutils}/bin/touch /mnt/ssd/monitoring/.minioScrapeBearerToken
        fi
      '';
      wantedBy = [
        "var-lib-prometheus2.mount"
        "prometheus-minio.service"
      ];
    };
  };

  fileSystems."/var/lib/prometheus2" = {
    device = "/mnt/ssd/monitoring/prometheus2";
    options = [
      "bind"
      "x-systemd.before=prometheus.service"
      "x-systemd.wanted-by=prometheus.service"
    ];
  };

  sops.secrets = {
    "minio/envs" = {
      mode = "0400";
      owner = config.users.users.root.name;
      group = config.users.users.root.group;
    };
  };

  systemd.services = {
    prometheus-minio = {
      before = [ "prometheus.service" ];
      serviceConfig = let
        entrypoint = pkgs.writeTextFile {
          name = "entrypoint.sh";
          text = ''
            #!/bin/bash

            # args: host port
            check_port_is_open() {
              local exit_status_code
              curl --silent --connect-timeout 1 --telnet-option "" telnet://"$1:$2" </dev/null
              exit_status_code=$?
              case $exit_status_code in
                49) return 0 ;;
                *) return "$exit_status_code" ;;
              esac
            }

            while true; do
              check_port_is_open ${lib.strings.stringAsChars (x: if x == ":" then " " else x) MINIO_ENDPOINT}
              if [ $? == 0 ]; then
                echo "Generating prometheus bearer token in the MinIO"

                mc alias set $ALIAS http://${MINIO_ENDPOINT} $MINIO_ROOT_USER $MINIO_ROOT_PASSWORD

                mc admin prometheus generate $ALIAS | grep bearer_token | awk '{ print $2 }' | tr -d '\n' > /mnt/.minioScrapeBearerToken

                break
              fi
              echo "Waiting for MinIO availability"
              sleep 1
            done
          '';
          executable = true;
        };
        MINIO_CLIENT_IMAGE = (import /etc/nixos/variables.nix).minio_client_image;
      in {
        Type = "oneshot";
        ExecStart = ''${pkgs.bash}/bin/bash -c ' \
          ${pkgs.${CONTAINERS_BACKEND}}/bin/${CONTAINERS_BACKEND} run \
            --rm \
            --name prometheus-minio \
            --volume /mnt/ssd/monitoring/.minioScrapeBearerToken:/mnt/.minioScrapeBearerToken \
            --volume ${entrypoint}:/entrypoint.sh \
            --env-file ${config.sops.secrets."minio/envs".path} \
            --env ALIAS=local \
            --entrypoint /entrypoint.sh \
            ${MINIO_CLIENT_IMAGE}'
        '';
      };
      wantedBy = [ "prometheus.service" ];
    };
  };

  services = {
    prometheus = {
      enable = true;
      listenAddress = "127.0.0.1";
      port = 9090;
      webExternalUrl = "http://${DOMAIN_NAME_INTERNAL}/prometheus";
      stateDir = "prometheus2";
      retentionTime = "15d";
      checkConfig = "syntax-only";
      enableReload = true;
      globalConfig = {
        scrape_interval = "1m";
        scrape_timeout = "10s";
        evaluation_interval = "1m";
      };
      scrapeConfigs = [
        {
          job_name = "minio-job";
          scheme = "http";
          static_configs = [{
            targets = [ "${MINIO_ENDPOINT}" ];
          }];
          metrics_path = "/minio/v2/metrics/cluster";
          bearer_token_file = "/mnt/ssd/monitoring/.minioScrapeBearerToken";
        }
        {
          job_name = "prometheus";
          scheme = "http";
          static_configs = [{
            targets = [ "${config.services.prometheus.listenAddress}:${toString config.services.prometheus.port}" ];
          }];
          metrics_path = "/prometheus/metrics";
        }
      ];
      remoteWrite = [{
        url = "http://127.0.0.1:9009/mimir/api/v1/push";
        write_relabel_configs = [{
          source_labels = [
            "__name__"
            "instance"
            "job"
          ];
          regex = ".*;${config.services.prometheus.listenAddress}:${toString config.services.prometheus.port};prometheus";
          action = "drop";
        }];
      }];
    };
  };

  systemd.services = {
    prometheus = {
      serviceConfig = {
        CPUQuota = "2%";
        MemoryHigh = "486M";
        MemoryMax = "512M";
      };
    };
  };

  sops.secrets = {
    "prometheus/nginx_file" = {
      mode = "0400";
      owner = config.services.nginx.user;
      group = config.services.nginx.group;
    };
  };

  services = {
    nginx = {
      virtualHosts.${DOMAIN_NAME_INTERNAL} = {
        locations."/prometheus" = {
          proxyPass = "http://${config.services.prometheus.listenAddress}:${toString config.services.prometheus.port}";
          basicAuthFile = config.sops.secrets."prometheus/nginx_file".path;
        };
      };
    };
  };

  sops.secrets = {
    "1password" = {
      mode = "0400";
      owner = config.users.users.root.name;
      group = config.users.users.root.group;
    };
  };

  sops.secrets = {
    "prometheus/nginx_envs" = {
      mode = "0400";
      owner = config.users.users.root.name;
      group = config.users.users.root.group;
    };
  };

  systemd.services = {
    prometheus-1password = {
      after = [ "prometheus.service" ];
      preStart = "${pkgs.coreutils}/bin/sleep $((RANDOM % 21))";
      serviceConfig = let
        entrypoint = pkgs.writeTextFile {
          name = "entrypoint.sh";
          text = ''
            #!/bin/bash

            SESSION_TOKEN=$(echo "$OP_MASTER_PASSWORD" | op account add \
              --address $OP_SUBDOMAIN.1password.com \
              --email $OP_EMAIL_ADDRESS \
              --secret-key $OP_SECRET_KEY \
              --signin --raw)

            op item get Prometheus \
              --vault 'Local server' \
              --session $SESSION_TOKEN > /dev/null

            if [ $? != 0 ]; then
              op item template get Login --session $SESSION_TOKEN | op item create --vault 'Local server' - \
                --title Prometheus \
                --url http://${DOMAIN_NAME_INTERNAL}/prometheus \
                username=$PROMETHEUS_NGINX_USERNAME \
                password=$PROMETHEUS_NGINX_PASSWORD \
                --session $SESSION_TOKEN > /dev/null
            fi
          '';
          executable = true;
        };
        ONE_PASSWORD_IMAGE = (import /etc/nixos/variables.nix).one_password_image;
      in {
        Type = "oneshot";
        ExecStart = ''${pkgs.bash}/bin/bash -c ' \
          ${pkgs.${CONTAINERS_BACKEND}}/bin/${CONTAINERS_BACKEND} run \
            --rm \
            --name prometheus-1password \
            --volume ${entrypoint}:/entrypoint.sh \
            --env-file ${config.sops.secrets."1password".path} \
            --env-file ${config.sops.secrets."prometheus/nginx_envs".path} \
            --entrypoint /entrypoint.sh \
            ${ONE_PASSWORD_IMAGE}'
        '';
      };
      wantedBy = [ "prometheus.service" ];
    };
  };
}
