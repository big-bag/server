{ config, ... }:

let
  CONTAINERS_BACKEND = config.virtualisation.oci-containers.backend;
in

{
  users.groups.${CONTAINERS_BACKEND}.members = [ "grafana-agent" ];

  services = {
    grafana-agent = {
      settings = {
        integrations = {
          cadvisor = {
            enabled = true;
            scrape_integration = true;
            scrape_interval = "1m";
            scrape_timeout = "10s";
            store_container_labels = false;
            enabled_metrics = [
              "cpu"
              "memory"
              "disk"
              "network"
            ];
            containerd = "/run/docker/containerd/containerd.sock";
            docker_only = true;
          };
        };
      };
    };
  };

  systemd.services = {
    grafana-agent = {
      serviceConfig = {
        User = "root";
      };
    };
  };
}
