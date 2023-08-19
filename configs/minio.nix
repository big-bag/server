{ config, pkgs, ... }:

let
  CONTAINERS_BACKEND = config.virtualisation.oci-containers.backend;
  DOMAIN_NAME_INTERNAL = (import ./connection-parameters.nix).domain_name_internal;
in

{
  systemd.services = {
    minio-prepare = {
      before = [ "${CONTAINERS_BACKEND}-minio.service" ];
      serviceConfig = {
        Type = "oneshot";
      };
      script = "${pkgs.coreutils}/bin/mkdir -p /mnt/ssd/data-stores";
      wantedBy = [ "${CONTAINERS_BACKEND}-minio.service" ];
    };
  };

  sops.secrets = {
    "minio/envs" = {
      mode = "0400";
      owner = config.users.users.root.name;
      group = config.users.users.root.group;
    };
  };

  virtualisation = {
    oci-containers = {
      containers = {
        minio = let
          IP_ADDRESS = (import ./connection-parameters.nix).ip_address;
        in {
          autoStart = true;
          ports = [
            "${IP_ADDRESS}:9000:9000"
            "127.0.0.1:9001:9001"
          ];
          volumes = [
            "/mnt/ssd/data-stores/minio/data:/data"
            "/mnt/ssd/data-stores/minio/config:/config"
          ];
          environmentFiles = [ config.sops.secrets."minio/envs".path ];
          environment = {
            MINIO_REGION = "eu-west-3";
            MINIO_BROWSER = "on";
            MINIO_BROWSER_REDIRECT_URL = "http://${DOMAIN_NAME_INTERNAL}/minio";
            MINIO_PROMETHEUS_URL = "http://${IP_ADDRESS}:9090/prometheus";
            MINIO_PROMETHEUS_JOB_ID = "minio-job";
          };
          extraOptions = [
            "--ulimit=nofile=65536:65536"
            "--cpus=0.25"
            "--memory-reservation=973m"
            "--memory=1024m"
          ];
          image = (import /etc/nixos/variables.nix).minio_image;
          cmd = [
            "server"
            "/data"
            "--json"
            "--address"
            ":9000"
            "--console-address"
            ":9001"
            "--config-dir=/config"
          ];
        };
      };
    };
  };

  services = {
    nginx = {
      upstreams."minio_console" = {
        extraConfig = "least_conn;";
        servers = { "127.0.0.1:9001" = {}; };
      };

      virtualHosts.${DOMAIN_NAME_INTERNAL} = {
        extraConfig = ''
          # Allow special characters in headers
          ignore_invalid_headers off;
        '';

        locations."/minio/" = {
          extraConfig = ''
            # Allow any size file to be uploaded.
            # Set to a value such as 1000m; to restrict file size to a specific value
            client_max_body_size 0;

            # Disable buffering
            proxy_buffering off;
            proxy_request_buffering off;

            rewrite ^/minio/(.*) /$1 break;
            proxy_set_header Host $host;
            proxy_set_header X-Real-IP $remote_addr;
            proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto $scheme;
            proxy_set_header X-NginX-Proxy true;

            # This is necessary to pass the correct IP to be hashed
            real_ip_header X-Real-IP;

            proxy_connect_timeout 300;

            # To support websockets in MinIO versions released after January 2023
            proxy_http_version 1.1;
            proxy_set_header Upgrade $http_upgrade;
            proxy_set_header Connection "upgrade";

            chunked_transfer_encoding off;
          '';
          proxyPass = "http://minio_console"; # This uses the upstream directive definition
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
      after = [ "${CONTAINERS_BACKEND}-minio.service" ];
      preStart = "${pkgs.coreutils}/bin/sleep $((RANDOM % 21))";
      serviceConfig = {
        Type = "oneshot";
        EnvironmentFile = [
          config.sops.secrets."1password".path
          config.sops.secrets."minio/envs".path
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

        ${pkgs._1password}/bin/op item get MinIO \
          --vault 'Local server' \
          --session $SESSION_TOKEN > /dev/null

        if [ $? != 0 ]; then
          ${pkgs._1password}/bin/op item template get Database --session $SESSION_TOKEN | ${pkgs._1password}/bin/op item create --vault 'Local server' - \
            --title MinIO \
            website[url]=http://${DOMAIN_NAME_INTERNAL}/minio \
            username=$MINIO_ROOT_USER \
            password=$MINIO_ROOT_PASSWORD \
            notesPlain='username -> Access Key, password -> Secret Key' \
            --session $SESSION_TOKEN > /dev/null
        fi
      '';
      wantedBy = [ "${CONTAINERS_BACKEND}-minio.service" ];
    };
  };
}
