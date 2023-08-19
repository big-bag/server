{
  services = {
    grafana-agent = {
      settings = {
        integrations = {
          node_exporter = {
            enabled = true;
            scrape_interval = "2s";
            scrape_timeout = "2s";
          };
        };
      };
    };
  };
}
