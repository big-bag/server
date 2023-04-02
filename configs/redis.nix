{ config, ... }:

let
  redis-instance = "local";
in

{
  fileSystems."/var/lib/redis-${redis-instance}" = {
    device = "/mnt/ssd/data-stores/redis-${redis-instance}";
    options = [ "bind" ];
  };

  services = {
    redis = {
      vmOverCommit = true;
      servers = {
        ${redis-instance} = {
          enable = true;
          bind = "127.0.0.1";
          port = 6379;
          requirePass = "{{ redis_database_password }}";
          appendOnly = true;
          settings = {
            maxmemory = 1932735283; # 1,8 Gb * 1024 * 1024 * 1024 = 1932735283,2 bytes
          };
        };
      };
    };
  };

  systemd = {
    services = {
      "redis-${redis-instance}" = {
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
        redisinsight = {
          image = "redislabs/redisinsight:1.13.1";
          autoStart = true;
          extraOptions = [
            "--network=host"
            "--cpus=0.03125"
            "--memory-reservation=115m"
            "--memory=128m"
          ];
          environment = {
            RIHOST = "127.0.0.1";
            RIPORT = "8001";
            RITRUSTEDORIGINS = "https://{{ internal_domain_name }}";
            RIPROXYENABLE = "True";
            RIPROXYPATH = "/redisinsight/";
          };
        };

        redis-configure = {
          image = "redis:7.0.10-alpine3.17";
          autoStart = true;
          extraOptions = [
            "--network=host"
            "--cpus=0.01563"
            "--memory-reservation=58m"
            "--memory=64m"
          ];
          entrypoint = "/bin/sh";
          cmd = let
            instance-local = "
              {
                \"name\": \"Local\",
                \"connectionType\": \"STANDALONE\",
                \"host\": \"127.0.0.1\",
                \"port\": ${toString config.services.redis.servers.${redis-instance}.port},
                \"password\": \"{{ redis_database_password }}\"
              }
            ";
          in [
            "-c" "
              for i in `seq 1 300`; do
                wget -q -O - http://127.0.0.1:8001/healthcheck/ | grep \"OK\"
                if [ $? == 0 ]; then
                  wget -O - http://127.0.0.1:8001/api/instance/ --header 'Content-Type: application/json' --post-data '${instance-local}'
                  echo 'ACL SETUSER {{ redis_monitoring_database_username }} +client +ping +info +config|get +cluster|info +slowlog +latency +memory +select +get +scan +xinfo +type +pfcount +strlen +llen +scard +zcard +hlen +xlen +eval allkeys on >{{ redis_monitoring_database_password }}' | redis-cli -h 127.0.0.1 -p ${toString config.services.redis.servers.${redis-instance}.port} -a '{{ redis_database_password }}'
                  exit 0
                fi
                sleep 1
              done
            "
          ];
        };
      };
    };
  };

  services = {
    nginx = {
      virtualHosts."{{ internal_domain_name }}" = {
        locations."/redisinsight/" = {
          proxyPass = "http://127.0.0.1:8001/";
          extraConfig = ''
            proxy_read_timeout 900;
            proxy_set_header   Host $host;
          '';
          basicAuthFile = /mnt/ssd/services/.redisinsightBasicAuthPassword;
        };
      };
    };
  };

  services = {
    grafana-agent = {
      settings = {
        integrations = {
          redis_exporter = {
            enabled = true;
            scrape_interval = "1m";
            redis_addr = "127.0.0.1:${toString config.services.redis.servers.${redis-instance}.port}";
            redis_user = "{{ redis_monitoring_database_username }}";
            redis_password = "{{ redis_monitoring_database_password }}";
          };
        };
      };
    };
  };
}
