{ config, pkgs, ... }:

{
  fileSystems."/var/lib/postgresql" = {
    device = "/mnt/ssd/data-stores/postgresql";
    options = [ "bind" ];
  };

  services = {
    postgresql = {
      enable = true;
      package = pkgs.postgresql_14;
      port = 5432;
      authentication = pkgs.lib.mkForce ''
        # TYPE  DATABASE        USER            ADDRESS                 METHOD

        # "local" is for Unix domain socket connections only
        local   all             all                                     peer
        # IPv4 local connections:
        host    all             all             127.0.0.1/32            md5
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
      initialScript = pkgs.writeText "Initial script" ''
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
      '';
    };
  };

  systemd = {
    services = {
      postgresql = {
        serviceConfig = {
          CPUQuota = "6,25%";
          MemoryHigh = 1932735283; # 1,8 Gb * 1024 * 1024 * 1024 = 1932735283,2 bytes
          MemoryMax = "2G";
        };
      };
    };
  };

  virtualisation = {
    oci-containers = {
      containers = {
        pgadmin = {
          image = "dpage/pgadmin4:6.21";
          autoStart = true;
          extraOptions = [
            "--network=host"
            "--cpus=0.0625"
            "--memory-reservation=230m"
            "--memory=256m"
          ];
          environment = {
            PGADMIN_DEFAULT_EMAIL = "default@{{ internal_domain_name }}";
            PGADMIN_DEFAULT_PASSWORD = "default";
            PGADMIN_DISABLE_POSTFIX = "True";
            PGADMIN_LISTEN_ADDRESS = "127.0.0.1";
            PGADMIN_LISTEN_PORT = "5050";
            PGADMIN_SERVER_JSON_FILE = "/var/lib/pgadmin/servers.json";
            PGADMIN_CONFIG_SERVER_MODE = "False";
            PGADMIN_CONFIG_MASTER_PASSWORD_REQUIRED = "False";
          };
          entrypoint = "/bin/sh";
          cmd = let
            servers = "
              {
                  \"Servers\": {
                      \"1\": {
                          \"Name\": \"Local\",
                          \"Group\": \"Servers\",
                          \"Host\": \"127.0.0.1\",
                          \"Port\": ${toString config.services.postgresql.port},
                          \"MaintenanceDB\": \"postgres\",
                          \"Username\": \"{{ postgres_pgadmin_database_username }}\",
                          \"PassFile\": \"/var/lib/pgadmin/.pgpass\"
                      }
                  }
              }
            ";
            pg-pass = "127.0.0.1:${toString config.services.postgresql.port}:postgres:{{ postgres_pgadmin_database_username }}:{{ postgres_pgadmin_database_password }}";
          in [
            "-c" "
              echo '${servers}' >> /var/lib/pgadmin/servers.json
              echo '${pg-pass}' >> /var/lib/pgadmin/.pgpass
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
          proxyPass = "http://127.0.0.1:5050/";
          basicAuthFile = /mnt/ssd/services/.pgadminBasicAuthPassword;
        };
      };
    };
  };

  services = {
    grafana-agent = {
      settings = {
        integrations = {
          postgres_exporter = {
            enabled = true;
            scrape_interval = "1m";
            data_source_names = [ "postgresql://{{ postgres_monitoring_database_username }}:{{ postgres_monitoring_database_password | replace('%', '%25') | replace('^', '%5E') | replace('&', '%26') | replace('*', '%2A') | replace('(', '%28') | replace(')', '%29') | replace('=', '%3D') | replace('+', '%2B') | replace('[', '%5B') | replace(']', '%5D') | replace('{', '%7B') | replace('}', '%7D') | replace('|', '%7C') | replace(';', '%3B') | replace(',', '%2C') | replace('<', '%3C') | replace('>', '%3E') | replace('/', '%2F') | replace('?', '%3F') }}@127.0.0.1:${toString config.services.postgresql.port}/postgres?sslmode=disable" ];
            autodiscover_databases = true;
          };
        };
      };
    };
  };
}
