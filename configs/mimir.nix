{ config, pkgs, ... }:

{
  systemd.services = {
    mimir-prepare = {
      before = [ "var-lib-private-mimir.mount" ];
      serviceConfig = {
        Type = "oneshot";
      };
      script = "${pkgs.coreutils}/bin/mkdir -p /mnt/ssd/monitoring";
      wantedBy = [ "var-lib-private-mimir.mount" ];
    };
  };

  fileSystems."/var/lib/private/mimir" = {
    device = "/mnt/ssd/monitoring/mimir";
    options = [
      "bind"
      "x-systemd.before=mimir.service"
      "x-systemd.wanted-by=mimir.service"
    ];
  };

  systemd.services = {
    mimir-minio = {
      before = [ "mimir.service" ];
      serviceConfig = let
        CONTAINERS_BACKEND = "${config.virtualisation.oci-containers.backend}";
        ENTRYPOINT = pkgs.writeTextFile {
          name = "entrypoint.sh";
          text = ''
            #!/bin/bash

            mc alias set $ALIAS http://${toString config.services.minio.listenAddress} $MINIO_ACCESS_KEY $MINIO_SECRET_KEY

            mc mb --ignore-existing $ALIAS/mimir-blocks
            mc anonymous set public $ALIAS/mimir-blocks

            mc mb --ignore-existing $ALIAS/mimir-ruler
            mc anonymous set public $ALIAS/mimir-ruler

            mc mb --ignore-existing $ALIAS/mimir-alertmanager
            mc anonymous set public $ALIAS/mimir-alertmanager
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
            --name mimir-minio \
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
      wantedBy = [ "mimir.service" ];
    };
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
            instance_addr = "127.0.0.1";
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
          bind_addr = [ "127.0.0.1" ];
        };
        common.storage = {
          backend = "s3";
          s3 = {
            endpoint = "${toString config.services.minio.listenAddress}";
            region = "${toString config.services.minio.region}";
            secret_access_key = "{{ minio_secret_key }}";
            access_key_id = "{{ minio_access_key }}";
            insecure = true;
          };
        };
      };
    };
  };

  systemd.services = {
    mimir = {
      serviceConfig = {
        StartLimitBurst = 0;
        CPUQuota = "6%";
        MemoryHigh = "1946M";
        MemoryMax = "2048M";
      };
    };
  };

  services = {
    nginx = {
      virtualHosts."{{ internal_domain_name }}" = {
        locations."/mimir/" = {
          proxyPass = "http://${toString config.services.mimir.configuration.server.http_listen_address}:${toString config.services.mimir.configuration.server.http_listen_port}";
          basicAuth = { {{ mimir_username }} = "{{ mimir_password }}"; };
        };
      };
    };
  };

  systemd.services = {
    mimir-1password = {
      after = [
        "mimir.service"
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

            op item get 'Mimir (generated)' \
              --vault 'Local server' \
              --session $SESSION_TOKEN > /dev/null

            if [ $? != 0 ]; then
              op item template get Login --session $SESSION_TOKEN | op item create --vault 'Local server' - \
                --title 'Mimir (generated)' \
                --url http://$INTERNAL_DOMAIN_NAME/mimir \
                username=$MIMIR_USERNAME \
                password=$MIMIR_PASSWORD \
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
            MIMIR_USERNAME = {{ mimir_username }}
            MIMIR_PASSWORD = {{ mimir_password }}
          '';
        };
        ExecStart = ''${pkgs.bash}/bin/bash -c ' \
          ${pkgs.${CONTAINERS_BACKEND}}/bin/${CONTAINERS_BACKEND} run \
            --rm \
            --name mimir-1password \
            --volume ${ENTRYPOINT}:/entrypoint.sh \
            --env OP_DEVICE=$OP_DEVICE \
            --env OP_MASTER_PASSWORD="$OP_MASTER_PASSWORD" \
            --env OP_SUBDOMAIN=$OP_SUBDOMAIN \
            --env OP_EMAIL_ADDRESS=$OP_EMAIL_ADDRESS \
            --env OP_SECRET_KEY=$OP_SECRET_KEY \
            --env INTERNAL_DOMAIN_NAME=$INTERNAL_DOMAIN_NAME \
            --env MIMIR_USERNAME=$MIMIR_USERNAME \
            --env MIMIR_PASSWORD=$MIMIR_PASSWORD \
            --entrypoint /entrypoint.sh \
            --cpus 0.01563 \
            --memory-reservation 61m \
            --memory 64m \
            ${ONE_PASSWORD_IMAGE}'
        '';
      };
      wantedBy = [ "mimir.service" ];
    };
  };
}
