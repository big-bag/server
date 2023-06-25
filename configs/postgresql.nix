{ config, pkgs, ... }:

{
  systemd.services = {
    postgresql-prepare = {
      before = [ "var-lib-postgresql.mount" ];
      serviceConfig = {
        Type = "oneshot";
      };
      script = "${pkgs.coreutils}/bin/mkdir -p /mnt/ssd/data-stores";
      wantedBy = [ "var-lib-postgresql.mount" ];
    };
  };

  fileSystems."/var/lib/postgresql" = {
    device = "/mnt/ssd/data-stores/postgresql";
    options = [
      "bind"
      "x-systemd.before=postgresql.service"
      "x-systemd.wanted-by=postgresql.service"
    ];
  };

  services = {
    postgresql = {
      enable = true;
      package = pkgs.postgresql_14;
      enableTCPIP = true;
      port = 5432;
      authentication = pkgs.lib.mkForce ''
        # TYPE  DATABASE        USER            ADDRESS                 METHOD

        # "local" is for Unix domain socket connections only
        local   all             all                                     peer
        # IPv4 local connections:
        host    all             all             {{ ansible_default_ipv4.address }}/32           md5
        # IPv4 docker connections
        host    all             all             172.17.0.0/16           md5
      '';
      settings = {
        max_connections = 100;              # (change requires restart)
        shared_buffers = "512MB";           # min 128kB (change requires restart)
        work_mem = "1310kB";                # min 64kB
        maintenance_work_mem = "128MB";     # min 1MB
        effective_io_concurrency = 200;     # 1-1000; 0 disables prefetching
        wal_buffers = "16MB";               # min 32kB, -1 sets based on shared_buffers (change requires restart)
        checkpoint_completion_target = 0.9; # checkpoint target duration, 0.0 - 1.0
        max_wal_size = "4GB";
        min_wal_size = "1GB";
        random_page_cost = 1.1;             # measured on an arbitrary scale
        effective_cache_size = "1536MB";
        default_statistics_target = 100;    # range 1-10000
      };
      initialScript = pkgs.writeTextFile {
        name = "initial.sh";
        text = ''
          CREATE ROLE {{ postgres_pgadmin_database_username }} WITH
              LOGIN
              CREATEDB
              CREATEROLE
              PASSWORD '{{ postgres_pgadmin_database_password }}';
          GRANT CONNECT ON DATABASE postgres TO {{ postgres_pgadmin_database_username }};

          CREATE ROLE {{ postgres_monitoring_database_username }} WITH
              LOGIN
              PASSWORD '{{ postgres_monitoring_database_password }}';
          GRANT pg_monitor TO {{ postgres_monitoring_database_username }};

          CREATE ROLE {{ postgres_gitlab_database_username }} WITH
              LOGIN
              PASSWORD '{{ postgres_gitlab_database_password }}';
          CREATE DATABASE gitlab OWNER {{ postgres_gitlab_database_username }};
          \c gitlab
          CREATE EXTENSION IF NOT EXISTS pg_trgm;
          CREATE EXTENSION IF NOT EXISTS btree_gist;
        '';
      };
    };
  };

  systemd.services = {
    postgresql = {
      serviceConfig = {
        CPUQuota = "6%";
        MemoryHigh = "1946M";
        MemoryMax = "2048M";
      };
    };
  };

  networking = {
    firewall = {
      allowedTCPPorts = [ 5432 ];
    };
  };

  virtualisation = {
    oci-containers = {
      containers = {
        pgadmin = {
          autoStart = true;
          ports = [ "127.0.0.1:5050:5050" ];
          volumes = let
            SERVERS = pkgs.writeTextFile {
              name = "servers.json";
              text = ''
                {
                    "Servers": {
                        "1": {
                            "Name": "Local",
                            "Group": "Servers",
                            "Host": "{{ ansible_default_ipv4.address }}",
                            "Port": ${toString config.services.postgresql.port},
                            "MaintenanceDB": "postgres",
                            "Username": "{{ postgres_pgadmin_database_username }}",
                            "PassFile": "/var/lib/pgadmin/.pgpass"
                        }
                    }
                }
              '';
            };
          in [ "${SERVERS}:/var/lib/pgadmin/servers.json" ];
          environment = {
            PGADMIN_DEFAULT_EMAIL = "default@{{ internal_domain_name }}";
            PGADMIN_DEFAULT_PASSWORD = "default";
            PGADMIN_DISABLE_POSTFIX = "True";
            PGADMIN_LISTEN_ADDRESS = "0.0.0.0";
            PGADMIN_LISTEN_PORT = "5050";
            PGADMIN_SERVER_JSON_FILE = "/var/lib/pgadmin/servers.json";
            PGADMIN_CONFIG_SERVER_MODE = "False";
            PGADMIN_CONFIG_MASTER_PASSWORD_REQUIRED = "False";
          };
          entrypoint = "/bin/sh";
          extraOptions = [
            "--cpus=0.0625"
            "--memory-reservation=243m"
            "--memory=256m"
          ];
          image = "dpage/pgadmin4:6.21";
          cmd = let
            PG_PASS = "{{ ansible_default_ipv4.address }}:${toString config.services.postgresql.port}:postgres:{{ postgres_pgadmin_database_username }}:{{ postgres_pgadmin_database_password }}";
          in [
            "-c" "
              echo '${PG_PASS}' >> /var/lib/pgadmin/.pgpass
              chmod 0600 /var/lib/pgadmin/.pgpass
              /entrypoint.sh
            "
          ];
        };
      };
    };
  };

  services = {
    nginx = {
      virtualHosts."{{ internal_domain_name }}" = {
        locations."/pgadmin4/" = {
          extraConfig = ''
            proxy_set_header X-Script-Name /pgadmin4;
            proxy_set_header X-Scheme $scheme;
            proxy_set_header Host $host;
            proxy_redirect off;
          '';
          proxyPass = "http://127.0.0.1:${toString config.virtualisation.oci-containers.containers.pgadmin.environment.PGADMIN_LISTEN_PORT}/";
          basicAuth = { {{ postgres_pgadmin_gui_username }} = "{{ postgres_pgadmin_gui_password }}"; };
        };
      };
    };
  };

  systemd.services = {
    postgresql-1password = let
      CONTAINERS_BACKEND = "${config.virtualisation.oci-containers.backend}";
    in {
      after = [
        "${CONTAINERS_BACKEND}-pgadmin.service"
        "nginx.service"
      ];
      serviceConfig = let
        ENTRYPOINT = pkgs.writeTextFile {
          name = "entrypoint.sh";
          text = ''
            #!/bin/bash

            SESSION_TOKEN=$(echo "$OP_MASTER_PASSWORD" | op account add \
              --address $OP_SUBDOMAIN.1password.com \
              --email $OP_EMAIL_ADDRESS \
              --secret-key $OP_SECRET_KEY \
              --signin --raw)

            op item get 'PostgreSQL (generated)' \
              --vault 'Local server' \
              --session $SESSION_TOKEN > /dev/null

            if [ $? != 0 ]; then
              op item template get Database --session $SESSION_TOKEN | op item create --vault 'Local server' - \
                --title 'PostgreSQL (generated)' \
                website[url]=http://$INTERNAL_DOMAIN_NAME/pgadmin4 \
                username=$PGADMIN_GUI_USERNAME \
                password=$PGADMIN_GUI_PASSWORD \
                'DB connection command - pgAdmin'[password]="PGPASSWORD=\"$PGADMIN_DB_PASSWORD\" psql -h {{ ansible_default_ipv4.address }} -p 5432 -U $PGADMIN_DB_USERNAME postgres" \
                'DB connection command - Monitoring'[password]="PGPASSWORD=\"$MONITORING_DB_PASSWORD\" psql -h {{ ansible_default_ipv4.address }} -p 5432 -U $MONITORING_DB_USERNAME postgres" \
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
            PGADMIN_GUI_USERNAME = {{ postgres_pgadmin_gui_username }}
            PGADMIN_GUI_PASSWORD = {{ postgres_pgadmin_gui_password }}
            PGADMIN_DB_USERNAME = {{ postgres_pgadmin_database_username }}
            PGADMIN_DB_PASSWORD = {{ postgres_pgadmin_database_password }}
            MONITORING_DB_USERNAME = {{ postgres_monitoring_database_username }}
            MONITORING_DB_PASSWORD = {{ postgres_monitoring_database_password }}
          '';
        };
        ExecStart = ''${pkgs.bash}/bin/bash -c ' \
          ${pkgs.${CONTAINERS_BACKEND}}/bin/${CONTAINERS_BACKEND} run \
            --rm \
            --name postgresql-1password \
            --volume ${ENTRYPOINT}:/entrypoint.sh \
            --env OP_DEVICE=$OP_DEVICE \
            --env OP_MASTER_PASSWORD="$OP_MASTER_PASSWORD" \
            --env OP_SUBDOMAIN=$OP_SUBDOMAIN \
            --env OP_EMAIL_ADDRESS=$OP_EMAIL_ADDRESS \
            --env OP_SECRET_KEY=$OP_SECRET_KEY \
            --env INTERNAL_DOMAIN_NAME=$INTERNAL_DOMAIN_NAME \
            --env PGADMIN_GUI_USERNAME=$PGADMIN_GUI_USERNAME \
            --env PGADMIN_GUI_PASSWORD=$PGADMIN_GUI_PASSWORD \
            --env PGADMIN_DB_USERNAME=$PGADMIN_DB_USERNAME \
            --env PGADMIN_DB_PASSWORD=$PGADMIN_DB_PASSWORD \
            --env MONITORING_DB_USERNAME=$MONITORING_DB_USERNAME \
            --env MONITORING_DB_PASSWORD=$MONITORING_DB_PASSWORD \
            --entrypoint /entrypoint.sh \
            --cpus 0.01563 \
            --memory-reservation 61m \
            --memory 64m \
            ${ONE_PASSWORD_IMAGE}'
        '';
      };
      wantedBy = [ "${CONTAINERS_BACKEND}-pgadmin.service" ];
    };
  };

  services = {
    grafana-agent = {
      settings = {
        integrations = {
          postgres_exporter = {
            enabled = true;
            scrape_interval = "1m";
            data_source_names = [ "postgresql://{{ postgres_monitoring_database_username }}:{{ postgres_monitoring_database_password | replace('%', '%25') | replace('^', '%5E') | replace('&', '%26') | replace('*', '%2A') | replace('(', '%28') | replace(')', '%29') | replace('=', '%3D') | replace('+', '%2B') | replace('[', '%5B') | replace(']', '%5D') | replace('{', '%7B') | replace('}', '%7D') | replace('|', '%7C') | replace(';', '%3B') | replace(',', '%2C') | replace('<', '%3C') | replace('>', '%3E') | replace('/', '%2F') | replace('?', '%3F') }}@{{ ansible_default_ipv4.address }}:${toString config.services.postgresql.port}/postgres?sslmode=disable" ];
            autodiscover_databases = true;
          };
        };
      };
    };
  };
}
