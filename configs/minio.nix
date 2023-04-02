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

  systemd = {
    services = {
      minio = {
        serviceConfig = {
          CPUQuota = "1,56%";
          MemoryHigh = "461M";
          MemoryMax = "512M";
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
            "--cpus=0.01563"
            "--memory-reservation=58m"
            "--memory=64m"
          ];
          volumes = [ "/mnt/ssd/services/.minioScrapeBearerToken:/mnt/.minioScrapeBearerToken" ];
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
            "
          ];
        };
      };
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
}
