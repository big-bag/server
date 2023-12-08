{ config, pkgs, ... }:

let
  IP_ADDRESS = (import ./connection-parameters.nix).ip_address;
  CONTAINERS_BACKEND = config.virtualisation.oci-containers.backend;
in

{
  systemd.services = {
    postgres-prepare = {
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
        host    all             all             ${IP_ADDRESS}/32           md5
        # IPv4 ${CONTAINERS_BACKEND} connections
        host    all             all             172.17.0.0/16           md5
      '';
      settings = {
        max_connections = 80;               # (change requires restart)
        shared_buffers = "512MB";           # min 128kB (change requires restart)
        huge_pages = "off";                 # on, off, or try (change requires restart)
        work_mem = "1638kB";                # min 64kB
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

  systemd.services = {
    postgres-configure = {
      after = [ "postgresql.service" ];
      serviceConfig = {
        Type = "oneshot";
      };
      script = ''
        while ! ${pkgs.netcat}/bin/nc -w 1 -v -z ${IP_ADDRESS} ${toString config.services.postgresql.port}
        do
          ${pkgs.coreutils}/bin/echo "Waiting for Postgres availability."
          ${pkgs.coreutils}/bin/sleep 1
        done

        ${pkgs.sudo}/bin/sudo -u postgres ${pkgs.postgresql_14}/bin/psql --variable=ON_ERROR_STOP=1 <<-EOSQL 2> /dev/null
          REVOKE CONNECT
              ON DATABASE postgres
              FROM PUBLIC;

          \connect postgres

          REVOKE ALL PRIVILEGES
              ON SCHEMA public
              FROM PUBLIC;
        EOSQL
      '';
      wantedBy = [ "postgresql.service" ];
    };
  };

  services = {
    grafana-agent = {
      settings = {
        logs = {
          configs = [{
            name = "postgres";
            clients = [{
              url = "http://${config.services.loki.configuration.server.http_listen_address}:${toString config.services.loki.configuration.server.http_listen_port}/loki/api/v1/push";
            }];
            positions = {
              filename = "/var/lib/private/grafana-agent/positions/postgres.yml";
            };
            scrape_configs = [{
              job_name = "journal";
              journal = {
                json = false;
                max_age = "12h";
                labels = {
                  systemd_job = "systemd-journal";
                };
                path = "/var/log/journal";
              };
              relabel_configs = [
                {
                  source_labels = [ "__journal__systemd_unit" ];
                  regex = "(postgres-prepare|var-lib-postgresql|postgresql|postgres-configure).(service|mount)";
                  action = "keep";
                }
                {
                  source_labels = [ "__journal__systemd_unit" ];
                  target_label = "systemd_unit";
                  action = "replace";
                }
              ];
            }];
          }];
        };
      };
    };
  };
}
