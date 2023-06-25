{ config, pkgs, ... }:

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

  systemd.services = {
    prometheus-minio = {
      before = [ "prometheus.service" ];
      serviceConfig = let
        CONTAINERS_BACKEND = "${config.virtualisation.oci-containers.backend}";
        ENTRYPOINT = pkgs.writeTextFile {
          name = "entrypoint.sh";
          text = ''
            #!/bin/bash

            mc alias set $ALIAS http://${toString config.services.minio.listenAddress} $MINIO_ACCESS_KEY $MINIO_SECRET_KEY
            mc admin prometheus generate $ALIAS | grep bearer_token | awk '{ print $2 }' | tr -d '\n' > /mnt/.minioScrapeBearerToken
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
            --name prometheus-minio \
            --volume /mnt/ssd/monitoring/.minioScrapeBearerToken:/mnt/.minioScrapeBearerToken \
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
      wantedBy = [ "prometheus.service" ];
    };
  };

  services = {
    prometheus = {
      enable = true;
      listenAddress = "127.0.0.1";
      port = 9090;
      webExternalUrl = "http://{{ internal_domain_name }}/prometheus";
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
            targets = [ "${toString config.services.minio.listenAddress}" ];
          }];
          metrics_path = "/minio/v2/metrics/cluster";
          bearer_token_file = "/mnt/ssd/monitoring/.minioScrapeBearerToken";
        }
        {
          job_name = "prometheus";
          scheme = "http";
          static_configs = [{
            targets = [ "${toString config.services.prometheus.listenAddress}:${toString config.services.prometheus.port}" ];
          }];
          metrics_path = "/prometheus/metrics";
        }
      ];
      remoteWrite = [{
        url = "http://${toString config.services.mimir.configuration.server.http_listen_address}:${toString config.services.mimir.configuration.server.http_listen_port}/mimir/api/v1/push";
        write_relabel_configs = [{
          source_labels = [
            "__name__"
            "instance"
            "job"
          ];
          regex = ".*;${toString config.services.prometheus.listenAddress}:${toString config.services.prometheus.port};prometheus";
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

  services = {
    nginx = {
      virtualHosts."{{ internal_domain_name }}" = {
        locations."/prometheus" = {
          proxyPass = "http://${toString config.services.prometheus.listenAddress}:${toString config.services.prometheus.port}";
          basicAuth = { {{ prometheus_username }} = "{{ prometheus_password }}"; };
        };
      };
    };
  };

  systemd.services = {
    prometheus-1password = {
      after = [
        "prometheus.service"
        "nginx.service"
      ];
      serviceConfig = let
        CONTAINERS_BACKEND = "${config.virtualisation.oci-containers.backend}";
        ENTRYPOINT = pkgs.writeTextFile {
          name = "entrypoint.sh";
          text = ''
            #!/bin/bash

            SESSION_TOKEN=$(echo "$OP_MASTER_PASSWORD" | op account add \
              --address $OP_SUBDOMAIN.1password.com \
              --email $OP_EMAIL_ADDRESS \
              --secret-key $OP_SECRET_KEY \
              --signin --raw)

            op item get 'Prometheus (generated)' \
              --vault 'Local server' \
              --session $SESSION_TOKEN > /dev/null

            if [ $? != 0 ]; then
              op item template get Login --session $SESSION_TOKEN | op item create --vault 'Local server' - \
                --title 'Prometheus (generated)' \
                --url http://$INTERNAL_DOMAIN_NAME/prometheus \
                username=$PROMETHEUS_USERNAME \
                password=$PROMETHEUS_PASSWORD \
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
            PROMETHEUS_USERNAME = {{ prometheus_username }}
            PROMETHEUS_PASSWORD = {{ prometheus_password }}
          '';
        };
        ExecStart = ''${pkgs.bash}/bin/bash -c ' \
          ${pkgs.${CONTAINERS_BACKEND}}/bin/${CONTAINERS_BACKEND} run \
            --rm \
            --name prometheus-1password \
            --volume ${ENTRYPOINT}:/entrypoint.sh \
            --env OP_DEVICE=$OP_DEVICE \
            --env OP_MASTER_PASSWORD="$OP_MASTER_PASSWORD" \
            --env OP_SUBDOMAIN=$OP_SUBDOMAIN \
            --env OP_EMAIL_ADDRESS=$OP_EMAIL_ADDRESS \
            --env OP_SECRET_KEY=$OP_SECRET_KEY \
            --env INTERNAL_DOMAIN_NAME=$INTERNAL_DOMAIN_NAME \
            --env PROMETHEUS_USERNAME=$PROMETHEUS_USERNAME \
            --env PROMETHEUS_PASSWORD=$PROMETHEUS_PASSWORD \
            --entrypoint /entrypoint.sh \
            --cpus 0.01563 \
            --memory-reservation 61m \
            --memory 64m \
            ${ONE_PASSWORD_IMAGE}'
        '';
      };
      wantedBy = [ "prometheus.service" ];
    };
  };
}
