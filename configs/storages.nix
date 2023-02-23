{ config, ... }:

{
  services.minio = {
    enable = true;
    listenAddress = "127.0.0.1:9000";
    consoleAddress = "127.0.0.1:9001";
    dataDir = [ "/mnt/ssd/storages/minio/data" ];
    configDir = "/mnt/ssd/storages/minio/config";
    region = "eu-west-3";
    browser = true;
    rootCredentialsFile = "/mnt/ssd/storages/.minioEnvironmentVariables";
  };

  virtualisation = {
    oci-containers = {
      containers = {
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

  services.nginx = {
    virtualHosts."{{ hostvars['localhost']['internal_domain_name'] }}" = {
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
}
