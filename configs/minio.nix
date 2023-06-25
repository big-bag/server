{ config, pkgs, ... }:

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

  services = {
    minio = {
      enable = true;
      listenAddress = "{{ ansible_default_ipv4.address }}:9000";
      consoleAddress = "127.0.0.1:9001";
      dataDir = [ "/mnt/ssd/data-stores/minio/data" ];
      configDir = "/mnt/ssd/data-stores/minio/config";
      region = "eu-west-3";
      browser = true;
      rootCredentialsFile = pkgs.writeTextFile {
        name = ".env";
        text = ''
          MINIO_ROOT_USER={{ minio_access_key }}
          MINIO_ROOT_PASSWORD={{ minio_secret_key }}
          MINIO_PROMETHEUS_URL=http://127.0.0.1:9090/prometheus
          MINIO_PROMETHEUS_JOB_ID=minio-job
          MINIO_BROWSER_REDIRECT_URL=http://{{ internal_domain_name }}/minio
        '';
      };
    };
  };

  systemd.services = {
    minio = {
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

  systemd.services = {
    minio-1password = {
      after = [
        "minio.service"
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

            op item get 'MinIO (generated)' \
              --vault 'Local server' \
              --session $SESSION_TOKEN > /dev/null

            if [ $? != 0 ]; then
              op item template get Database --session $SESSION_TOKEN | op item create --vault 'Local server' - \
                --title 'MinIO (generated)' \
                website[url]=http://$INTERNAL_DOMAIN_NAME/minio \
                username=$MINIO_ACCESS_KEY \
                password=$MINIO_SECRET_KEY \
                notesPlain='username -> Access Key, password -> Secret Key' \
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
            MINIO_ACCESS_KEY = {{ minio_access_key }}
            MINIO_SECRET_KEY = {{ minio_secret_key }}
          '';
        };
        ExecStart = ''${pkgs.bash}/bin/bash -c ' \
          ${pkgs.${CONTAINERS_BACKEND}}/bin/${CONTAINERS_BACKEND} run \
            --rm \
            --name minio-1password \
            --volume ${ENTRYPOINT}:/entrypoint.sh \
            --env OP_DEVICE=$OP_DEVICE \
            --env OP_MASTER_PASSWORD="$OP_MASTER_PASSWORD" \
            --env OP_SUBDOMAIN=$OP_SUBDOMAIN \
            --env OP_EMAIL_ADDRESS=$OP_EMAIL_ADDRESS \
            --env OP_SECRET_KEY=$OP_SECRET_KEY \
            --env INTERNAL_DOMAIN_NAME=$INTERNAL_DOMAIN_NAME \
            --env MINIO_ACCESS_KEY=$MINIO_ACCESS_KEY \
            --env MINIO_SECRET_KEY=$MINIO_SECRET_KEY \
            --entrypoint /entrypoint.sh \
            --cpus 0.01563 \
            --memory-reservation 61m \
            --memory 64m \
            ${ONE_PASSWORD_IMAGE}'
        '';
      };
      wantedBy = [ "minio.service" ];
    };
  };
}
