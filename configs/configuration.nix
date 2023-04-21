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
  # time.timeZone = "Europe/Amsterdam";

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

  services.nginx = {
    enable = true;
    sslDhparam = "${toString config.security.dhparams.path}/nginx.pem";
    virtualHosts = {
      "{{ internal_domain_name }}" = {
        listen = [
          { addr = "*"; port = 80; }
          { addr = "*"; port = 443; ssl = true; }
        ];
        kTLS = true;
        forceSSL = true;
        sslCertificate = "/mnt/ssd/services/nginx/*.{{ internal_domain_name }}.crt";
        sslCertificateKey = "/mnt/ssd/services/nginx/*.{{ internal_domain_name }}.key";
      };

      "gitlab.{{ internal_domain_name }}" = {
        listen = [
          { addr = "*"; port = 80; }
          { addr = "*"; port = 443; ssl = true; }
        ];
        kTLS = true;
        forceSSL = true;
        sslCertificate = "/mnt/ssd/services/nginx/*.{{ internal_domain_name }}.crt";
        sslCertificateKey = "/mnt/ssd/services/nginx/*.{{ internal_domain_name }}.key";
      };

      "registry.{{ internal_domain_name }}" = {
        listen = [
          { addr = "*"; port = 80; }
          { addr = "*"; port = 443; ssl = true; }
        ];
        kTLS = true;
        forceSSL = true;
        sslCertificate = "/mnt/ssd/services/nginx/*.{{ internal_domain_name }}.crt";
        sslCertificateKey = "/mnt/ssd/services/nginx/*.{{ internal_domain_name }}.key";
      };

      "pages.{{ internal_domain_name }}" = {
        listen = [
          { addr = "*"; port = 80; }
          { addr = "*"; port = 443; ssl = true; }
        ];
        kTLS = true;
        forceSSL = true;
        sslCertificate = "/mnt/ssd/services/nginx/*.{{ internal_domain_name }}.crt";
        sslCertificateKey = "/mnt/ssd/services/nginx/*.{{ internal_domain_name }}.key";
      };
    };
  };

  systemd.services.nginx = {
    serviceConfig = {
      CPUQuota = "0,049%";
      MemoryHigh = "14M";
      MemoryMax = "16M";
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
      backend = "podman";
    };
    podman = {
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

