# Edit this configuration file to define what should be installed on
# your system.  Help is available in the configuration.nix(5) man page
# and in the NixOS manual (accessible by running ‘nixos-help’).

{ config, pkgs, ... }:

{
  imports =
    [ # Include the results of the hardware scan.
      ./hardware-configuration.nix
      ./python.nix
      ./technical-account.nix
      ./disks.nix
      ./minio.nix
      ./mimir.nix
      ./prometheus.nix
      ./loki.nix
      ./grafana.nix
      ./grafana-agent.nix
      ./postgresql.nix
      ./redis.nix
      ./gitlab.nix
    ];

  # Use the systemd-boot EFI boot loader.
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  # networking.hostName = "nixos"; # Define your hostname.
  # Pick only one of the below networking options.
  # networking.wireless.enable = true;  # Enables wireless support via wpa_supplicant.
  # networking.networkmanager.enable = true;  # Easiest to use and most distros use this by default.

  # Set your time zone.
  time.timeZone = "Europe/Moscow";

  networking.timeServers = [
    "0.ru.pool.ntp.org"
    "1.ru.pool.ntp.org"
    "2.ru.pool.ntp.org"
    "3.ru.pool.ntp.org"
  ];

  services.timesyncd.extraConfig = ''
    FallbackNTP=0.nixos.pool.ntp.org 1.nixos.pool.ntp.org 2.nixos.pool.ntp.org 3.nixos.pool.ntp.org
  '';

  # Configure network proxy if necessary
  # networking.proxy.default = "http://user:password@proxy:port/";
  # networking.proxy.noProxy = "127.0.0.1,localhost,internal.domain";

  # Select internationalisation properties.
  # i18n.defaultLocale = "en_US.UTF-8";
  # console = {
  #   font = "Lat2-Terminus16";
  #   keyMap = "us";
  #   useXkbConfig = true; # use xkbOptions in tty.
  # };

  # Enable the X11 windowing system.
  # services.xserver.enable = true;


  

  # Configure keymap in X11
  # services.xserver.layout = "us";
  # services.xserver.xkbOptions = {
  #   "eurosign:e";
  #   "caps:escape" # map caps to escape.
  # };

  # Enable CUPS to print documents.
  # services.printing.enable = true;

  # Enable sound.
  # sound.enable = true;
  # hardware.pulseaudio.enable = true;

  # Enable touchpad support (enabled default in most desktopManager).
  # services.xserver.libinput.enable = true;

  # Define a user account. Don't forget to set a password with ‘passwd’.
  # users.users.jane = {
  #   isNormalUser = true;
  #   extraGroups = [ "wheel" ]; # Enable ‘sudo’ for the user.
  #   packages = with pkgs; [
  #     firefox
  #     thunderbird
  #   ];
  # };

  # BEGIN ANSIBLE MANAGED BLOCK WHEEL
  # Allow people in group wheel to run all commands without a password
  security.sudo.wheelNeedsPassword = false;
  # END ANSIBLE MANAGED BLOCK WHEEL

  # List packages installed in system profile. To search, run:
  # $ nix search wget
  environment.systemPackages = with pkgs; [
  #   vim # Do not forget to add an editor to edit configuration.nix! The Nano editor is also installed by default.
  #   wget
    # BEGIN ANSIBLE MANAGED BLOCK PARTED
    parted # For community.general.parted ansible module
    # END ANSIBLE MANAGED BLOCK PARTED
  ];

  # Some programs need SUID wrappers, can be configured further or are
  # started in user sessions.
  # programs.mtr.enable = true;
  # programs.gnupg.agent = {
  #   enable = true;
  #   enableSSHSupport = true;
  # };

  # List services that you want to enable:

  # Enable the OpenSSH daemon.
  services.openssh = {
    enable = true;
    permitRootLogin = "no";
    # BEGIN ANSIBLE MANAGED BLOCK SSH PORT
    ports = [ {{ server_ssh_port }} ];
    # END ANSIBLE MANAGED BLOCK SSH PORT
  };

  security.dhparams = {
    enable = true;
    path = "/mnt/ssd/services/dhparams";
    defaultBitSize = 4096;
    params = {
      nginx = {};
    };
  };

  systemd.services = {
    self-signed-certificate = {
      before = [ "nginx.service" ];
      serviceConfig = {
        Type = "oneshot";
      };
      script = let
        ca.cnf = "
          [req]
          default_bits       = 4096
          distinguished_name = req_distinguished_name
          prompt             = no
          default_md         = sha256
          req_extensions     = v3_req

          [req_distinguished_name]
          countryName         = RU
          stateOrProvinceName = Moscow
          localityName        = Moscow
          organizationName    = {{ internal_domain_name | replace('.',' ') | title }}, Ltd.
          commonName          = {{ internal_domain_name | replace('.','-') }}-ca

          [v3_req]
          basicConstraints     = critical, CA:true
          keyUsage             = critical, keyCertSign, cRLSign
          subjectKeyIdentifier = hash
        ";
        ca-intermediate.cnf = "
          [req]
          default_bits       = 4096
          distinguished_name = req_distinguished_name
          prompt             = no
          default_md         = sha256
          req_extensions     = v3_req

          [req_distinguished_name]
          countryName         = RU
          stateOrProvinceName = Moscow
          localityName        = Moscow
          organizationName    = {{ internal_domain_name | replace('.',' ') | title }}, Ltd.
          commonName          = {{ internal_domain_name | replace('.','-') }}-int-ca

          [v3_req]
          basicConstraints     = critical, CA:true
          keyUsage             = critical, keyCertSign, cRLSign
          subjectKeyIdentifier = hash
        ";
        server.cnf = "
          [req]
          prompt             = no
          default_bits       = 4096
          x509_extensions    = v3_req
          req_extensions     = v3_req
          default_md         = sha256
          distinguished_name = req_distinguished_name

          [req_distinguished_name]
          countryName         = RU
          stateOrProvinceName = Moscow
          localityName        = Moscow
          organizationName    = {{ internal_domain_name | replace('.',' ') | title }}, Ltd.
          commonName          = {{ internal_domain_name }}

          [v3_req]
          basicConstraints = CA:FALSE
          keyUsage         = nonRepudiation, digitalSignature, keyEncipherment, keyAgreement
          extendedKeyUsage = critical, serverAuth
          subjectAltName   = @alt_names

          [alt_names]
          DNS.1 = {{ internal_domain_name }}
          DNS.2 = gitlab.{{ internal_domain_name }}
          DNS.3 = registry.{{ internal_domain_name }}
          DNS.4 = pages.{{ internal_domain_name }}
        ";
        user.cnf = "
          [req]
          prompt             = no
          default_bits       = 2048
          x509_extensions    = v3_req
          req_extensions     = v3_req
          default_md         = sha256
          distinguished_name = req_distinguished_name

          [req_distinguished_name]
          countryName         = RU
          stateOrProvinceName = Moscow
          localityName        = Moscow
          organizationName    = {{ internal_domain_name | replace('.',' ') | title }}, Ltd.
          commonName          = user.{{ internal_domain_name }}

          [v3_req]
          basicConstraints = CA:FALSE
          keyUsage         = nonRepudiation, digitalSignature, keyEncipherment, keyAgreement
          extendedKeyUsage = critical, clientAuth
        ";
      in ''
        ${pkgs.coreutils}/bin/mkdir -p /mnt/ssd/services/ca
        ${pkgs.coreutils}/bin/mkdir -p /mnt/ssd/services/nginx

        cd /mnt/ssd/services/ca

        if ! [ -f ca.crt ]; then
          ${pkgs.coreutils}/bin/echo "Creating Self-Signed Root CA certificate and key"
          ${pkgs.coreutils}/bin/echo '${ca.cnf}' > ca.cnf
          ${pkgs.openssl}/bin/openssl req \
            -new \
            -nodes \
            -x509 \
            -keyout ca.key \
            -out ca.crt \
            -config ca.cnf \
            -extensions v3_req \
            -days 1826 # 5 years
        fi

        if ! [ -f ca.pem ]; then
          ${pkgs.coreutils}/bin/echo "Creating Intermediate CA certificate and key"
          ${pkgs.coreutils}/bin/echo '${ca-intermediate.cnf}' > ca-intermediate.cnf
          ${pkgs.openssl}/bin/openssl req \
            -new \
            -nodes \
            -keyout ca_int.key \
            -out ca_int.csr \
            -config ca-intermediate.cnf \
            -extensions v3_req
          ${pkgs.openssl}/bin/openssl req -in ca_int.csr -noout -verify
          ${pkgs.openssl}/bin/openssl x509 \
            -req \
            -CA ca.crt \
            -CAkey ca.key \
            -CAcreateserial \
            -in ca_int.csr \
            -out ca_int.crt \
            -extfile ca-intermediate.cnf \
            -extensions v3_req \
            -days 365 # 1 year
          ${pkgs.openssl}/bin/openssl verify -CAfile ca.crt ca_int.crt
          ${pkgs.coreutils}/bin/echo "Creating CA chain"
          ${pkgs.coreutils}/bin/cat ca_int.crt ca.crt > ca.pem
        fi

        if ! [ -f server.crt ]; then
          ${pkgs.coreutils}/bin/echo "Creating server (Nginx) certificate and key"
          ${pkgs.coreutils}/bin/echo '${server.cnf}' > server.cnf
          ${pkgs.openssl}/bin/openssl req \
            -new \
            -nodes \
            -keyout server.key \
            -out server.csr \
            -config server.cnf
          ${pkgs.openssl}/bin/openssl req -in server.csr -noout -verify
          ${pkgs.openssl}/bin/openssl x509 \
            -req \
            -CA ca_int.crt \
            -CAkey ca_int.key \
            -CAcreateserial \
            -in server.csr \
            -out server.crt \
            -extfile server.cnf \
            -extensions v3_req \
            -days 365 # 1 year
          ${pkgs.openssl}/bin/openssl verify -CAfile ca.pem server.crt
        fi

        if ! [ -f user.pfx ]; then
          ${pkgs.coreutils}/bin/echo "Creating user certificate and key"
          ${pkgs.coreutils}/bin/echo '${user.cnf}' > user.cnf
          ${pkgs.openssl}/bin/openssl req \
            -new \
            -nodes \
            -keyout user.key \
            -out user.csr \
            -config user.cnf
          ${pkgs.openssl}/bin/openssl req -in user.csr -noout -verify
          ${pkgs.openssl}/bin/openssl x509 \
            -req \
            -CA ca.crt \
            -CAkey ca.key \
            -CAcreateserial \
            -in user.csr \
            -out user.crt \
            -extfile user.cnf \
            -extensions v3_req \
            -days 365 # 1 year
          ${pkgs.openssl}/bin/openssl verify -CAfile ca.pem user.crt
          ${pkgs.openssl}/bin/openssl pkcs12 \
            -export \
            -in user.crt \
            -inkey user.key \
            -certfile ca.pem \
            -out user.pfx \
            -passout pass:
          ${pkgs.openssl}/bin/openssl verify -CAfile ca.pem user.pfx
        fi

        ${pkgs.coreutils}/bin/cp --update server.{crt,key} /mnt/ssd/services/nginx/
        ${pkgs.coreutils}/bin/chmod 0604 /mnt/ssd/services/nginx/server.key
        ${pkgs.coreutils}/bin/cp --update ca.pem /mnt/ssd/services/nginx/
      '';
      wantedBy = [ "nginx.service" ];
    };
  };

  services.nginx = {
    enable = true;
    sslDhparam = "${toString config.security.dhparams.path}/nginx.pem";
    virtualHosts = {
      "{{ internal_domain_name }}" = {
        listen = [
          { addr = "{{ ansible_default_ipv4.address }}"; port = 80; }
          { addr = "{{ ansible_default_ipv4.address }}"; port = 443; ssl = true; }
        ];
        kTLS = true;
        forceSSL = true;
        sslCertificate = "/mnt/ssd/services/nginx/server.crt";
        sslCertificateKey = "/mnt/ssd/services/nginx/server.key";
        # Authentication based on a client certificate
        extraConfig = ''
          ssl_client_certificate /mnt/ssd/services/nginx/ca.pem;
          ssl_verify_client      on;
        '';
      };

      "gitlab.{{ internal_domain_name }}" = {
        listen = [
          { addr = "{{ ansible_default_ipv4.address }}"; port = 80; }
          { addr = "{{ ansible_default_ipv4.address }}"; port = 443; ssl = true; }
        ];
        kTLS = true;
        forceSSL = true;
        sslCertificate = "/mnt/ssd/services/nginx/server.crt";
        sslCertificateKey = "/mnt/ssd/services/nginx/server.key";
        # Authentication based on a client certificate
        extraConfig = ''
          ssl_client_certificate /mnt/ssd/services/nginx/ca.pem;
          ssl_verify_client      on;
        '';
      };

      "registry.{{ internal_domain_name }}" = {
        listen = [
          { addr = "{{ ansible_default_ipv4.address }}"; port = 80; }
          { addr = "{{ ansible_default_ipv4.address }}"; port = 443; ssl = true; }
        ];
        kTLS = true;
        forceSSL = true;
        sslCertificate = "/mnt/ssd/services/nginx/server.crt";
        sslCertificateKey = "/mnt/ssd/services/nginx/server.key";
        # Authentication based on a client certificate
        extraConfig = ''
          ssl_client_certificate /mnt/ssd/services/nginx/ca.pem;
          ssl_verify_client      on;
        '';
      };

      "pages.{{ internal_domain_name }}" = {
        listen = [
          { addr = "{{ ansible_default_ipv4.address }}"; port = 80; }
          { addr = "{{ ansible_default_ipv4.address }}"; port = 443; ssl = true; }
        ];
        kTLS = true;
        forceSSL = true;
        sslCertificate = "/mnt/ssd/services/nginx/server.crt";
        sslCertificateKey = "/mnt/ssd/services/nginx/server.key";
        # Authentication based on a client certificate
        extraConfig = ''
          ssl_client_certificate /mnt/ssd/services/nginx/ca.pem;
          ssl_verify_client      on;
        '';
      };
    };
  };

  systemd.services = {
    nginx = {
      serviceConfig = {
        CPUQuota = "1%";
        MemoryHigh = "15M";
        MemoryMax = "16M";
      };
    };
  };

  # Open ports in the firewall.
  networking.firewall.allowedTCPPorts = [
    80
    443
  ];
  # networking.firewall.allowedUDPPorts = [ ... ];
  # Or disable the firewall altogether.
  # networking.firewall.enable = false;

  virtualisation = {
    oci-containers = {
      backend = "docker";
    };
    docker = {
      enable = true;
    };
  };

  # Copy the NixOS configuration file and link it from the resulting system
  # (/run/current-system/configuration.nix). This is useful in case you
  # accidentally delete configuration.nix.
  # system.copySystemConfiguration = true;

  # This value determines the NixOS release from which the default
  # settings for stateful data, like file locations and database versions
  # on your system were taken. It‘s perfectly fine and recommended to leave
  # this value at the release version of the first install of this system.
  # Before changing this value read the documentation for this option
  # (e.g. man configuration.nix or on https://nixos.org/nixos/options.html).
  system.stateVersion = "22.05"; # Did you read the comment?

}

