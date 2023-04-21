{ config, pkgs, ... }:

{
  services = {
    minio = {
      enable = true;
      listenAddress = "127.0.0.1:9000";
      consoleAddress = "127.0.0.1:9001";
      dataDir = [ "/mnt/ssd/data-stores/minio/data" ];
      configDir = "/mnt/ssd/data-stores/minio/config";
      region = "eu-west-3";
      browser = true;
      rootCredentialsFile = pkgs.writeText "Environment variables" ''
        MINIO_ROOT_USER={{ minio_access_key }}
        MINIO_ROOT_PASSWORD={{ minio_secret_key }}
        MINIO_PROMETHEUS_URL=http://127.0.0.1:9090/prometheus
        MINIO_PROMETHEUS_JOB_ID=minio-job
        MINIO_BROWSER_REDIRECT_URL=http://{{ internal_domain_name }}/minio
      '';
    };
  };

  services = {
    nginx = {
      virtualHosts."{{ internal_domain_name }}" = {
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
      };
    };
  };

  virtualisation = {
    oci-containers = {
      containers = {
        minio-client = {
          image = "minio/mc:RELEASE.2023-03-23T20-03-04Z";
          autoStart = true;
          extraOptions = [
            "--network=host"
            "--cpus=0.03125"
            "--memory-reservation=115m"
            "--memory=128m"
          ];
          volumes = [ "/mnt/ssd/monitoring/.minioScrapeBearerToken:/mnt/.minioScrapeBearerToken" ];
          environment = { ALIAS = "local"; };
          entrypoint = "/bin/sh";
          cmd = [
            "-c" "
              mc alias set $ALIAS http://${toString config.services.minio.listenAddress} {{ minio_access_key }} {{ minio_secret_key }}
              mc admin prometheus generate $ALIAS | grep bearer_token | awk '{ print $2 }' | tr -d '\n' > /mnt/.minioScrapeBearerToken

              mc mb --ignore-existing $ALIAS/mimir-blocks
              mc anonymous set public $ALIAS/mimir-blocks

              mc mb --ignore-existing $ALIAS/mimir-ruler
              mc anonymous set public $ALIAS/mimir-ruler

              mc mb --ignore-existing $ALIAS/mimir-alertmanager
              mc anonymous set public $ALIAS/mimir-alertmanager

              mc mb --ignore-existing $ALIAS/loki
              mc anonymous set public $ALIAS/loki

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
            "
          ];
        };

        op-minio = {
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

              op item get 'MinIO (generated)' \\
                --vault 'Local server' \\
                --session $SESSION_TOKEN

              if [ $? != 0 ]; then
                op item template get Database --session $SESSION_TOKEN | op item create --vault 'Local server' - \\
                  --title 'MinIO (generated)' \\
                  website[url]=http://{{ internal_domain_name }}/minio \\
                  username='{{ minio_access_key }}' \\
                  password='{{ minio_secret_key }}' \\
                  notesPlain='username -> Access Key, password -> Secret Key' \\
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
      minio = {
        serviceConfig = {
          CPUQuota = "1,56%";
          MemoryHigh = "461M";
          MemoryMax = "512M";
        };
      };

      podman-minio-client = {
        serviceConfig = {
          RestartPreventExitStatus = 0;
        };
      };

      podman-op-minio = {
        serviceConfig = {
          RestartPreventExitStatus = 0;
        };
      };
    };
  };
}
