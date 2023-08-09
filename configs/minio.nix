{ config, pkgs, ... }:

let
  DOMAIN_NAME_INTERNAL = (import ./connection-parameters.nix).domain_name_internal;
in

{
  systemd.services = {
    minio-prepare = {
      before = [ "minio.service" ];
      serviceConfig = {
        Type = "oneshot";
      };
      script = "${pkgs.coreutils}/bin/mkdir -p /mnt/ssd/data-stores";
      wantedBy = [ "minio.service" ];
    };
  };

  sops.secrets = {
    "minio/envs" = {
      mode = "0400";
      owner = config.users.users.root.name;
      group = config.users.users.root.group;
    };
  };

  services = {
    minio = let
      IP_ADDRESS = (import ./connection-parameters.nix).ip_address;
    in {
      enable = true;
      listenAddress = "${IP_ADDRESS}:9000";
      consoleAddress = "127.0.0.1:9001";
      dataDir = [ "/mnt/ssd/data-stores/minio/data" ];
      configDir = "/mnt/ssd/data-stores/minio/config";
      region = "eu-west-3";
      browser = true;
      rootCredentialsFile = config.sops.secrets."minio/envs".path;
    };
  };

  systemd.services = {
    minio = {
      environment = {
        MINIO_PROMETHEUS_URL = "http://127.0.0.1:9090/prometheus";
        MINIO_PROMETHEUS_JOB_ID = "minio-job";
        MINIO_BROWSER_REDIRECT_URL = "http://${DOMAIN_NAME_INTERNAL}/minio";
      };
      serviceConfig = {
        CPUQuota = "3%";
        MemoryHigh = "973M";
        MemoryMax = "1024M";
      };
    };
  };

  networking = {
    firewall = {
      allowedTCPPorts = [ 9000 ];
    };
  };

  services = {
    nginx = {
      virtualHosts.${DOMAIN_NAME_INTERNAL} = {
        locations."/minio" = {
          extraConfig = ''
            rewrite ^/minio/(.*) /$1 break;
            proxy_set_header Host $host;

            # Proxy Minio WebSocket connections.
            proxy_http_version 1.1;
            proxy_set_header Upgrade    $http_upgrade;
            proxy_set_header Connection $connection_upgrade;
          '';
          proxyPass = "http://${config.services.minio.consoleAddress}";
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

  systemd.services = {
    minio-1password = {
      after = [ "minio.service" ];
      preStart = "${pkgs.coreutils}/bin/sleep $((RANDOM % 21))";
      serviceConfig = let
        CONTAINERS_BACKEND = config.virtualisation.oci-containers.backend;
        entrypoint = pkgs.writeTextFile {
          name = "entrypoint.sh";
          text = ''
            #!/bin/bash

            SESSION_TOKEN=$(echo "$OP_MASTER_PASSWORD" | op account add \
              --address $OP_SUBDOMAIN.1password.com \
              --email $OP_EMAIL_ADDRESS \
              --secret-key $OP_SECRET_KEY \
              --signin --raw)

            op item get MinIO \
              --vault 'Local server' \
              --session $SESSION_TOKEN > /dev/null

            if [ $? != 0 ]; then
              op item template get Database --session $SESSION_TOKEN | op item create --vault 'Local server' - \
                --title MinIO \
                website[url]=http://${DOMAIN_NAME_INTERNAL}/minio \
                username=$MINIO_ROOT_USER \
                password=$MINIO_ROOT_PASSWORD \
                notesPlain='username -> Access Key, password -> Secret Key' \
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
            --name minio-1password \
            --volume ${entrypoint}:/entrypoint.sh \
            --env-file ${config.sops.secrets."1password".path} \
            --env-file ${config.sops.secrets."minio/envs".path} \
            --entrypoint /entrypoint.sh \
            ${ONE_PASSWORD_IMAGE}'
        '';
      };
      wantedBy = [ "minio.service" ];
    };
  };
}
