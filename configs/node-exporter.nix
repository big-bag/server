{
  services = {
    grafana-agent = {
      settings = {
        integrations = {
          node_exporter = {
            enabled = true;
            scrape_integration = true;
            scrape_interval = "10s"; # Defaults to "1m"
            scrape_timeout = "10s"; # Defaults to "10s"
            set_collectors = [
              "cpu"
              "diskstats"
              "filesystem"
              "loadavg"
              "meminfo"
              "netdev"
            ];
            filesystem_mount_points_exclude = "^/(dev|proc|sys|run|var|boot|nix)($|/)";
            filesystem_fs_types_exclude = "^(devtmpfs|tmpfs|vfat)$";
            netdev_device_exclude = "^(lo|docker.*|veth.*)$";
          };
        };
      };
    };
  };
}
