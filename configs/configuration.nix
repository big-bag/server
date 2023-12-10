# Edit this configuration file to define what should be installed on
# your system. Help is available in the configuration.nix(5) man page, on
# https://search.nixos.org/options and in the NixOS manual (`nixos-help`).

{ config, lib, pkgs, ... }:

{
  imports =
    let
      SOPS_NIX_COMMIT = (import ./variables.nix).github_sops_nix_commit;
      SOPS_NIX_SHA256 = (import ./variables.nix).github_sops_nix_sha256;
    in
    [ # Include the results of the hardware scan.
      ./hardware-configuration.nix
      ./python.nix
      ./technical-account.nix
      ./disks.nix
      "${builtins.fetchTarball {
        url = "https://github.com/Mic92/sops-nix/archive/${SOPS_NIX_COMMIT}.tar.gz";
        sha256 = "${SOPS_NIX_SHA256}";
      }}/modules/sops"
      ./nginx.nix
      ./minio.nix
      ./mimir.nix
      ./loki.nix
      ./grafana-agent.nix
      ./nginx-exporter.nix
      ./prometheus.nix
      ./node-exporter.nix
      ./postgres.nix
      ./mattermost.nix
      ./redis.nix
      ./redis-exporter.nix
      ./redisinsight.nix
      ./gitlab.nix
      ./postgres-exporter.nix
      ./pgadmin.nix
      ./grafana.nix
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
  #   useXkbConfig = true; # use xkb.options in tty.
  # };

  # Enable the X11 windowing system.
  # services.xserver.enable = true;


  

  # Configure keymap in X11
  # services.xserver.xkb.layout = "us";
  # services.xserver.xkb.options = "eurosign:e,caps:escape";

  # Enable CUPS to print documents.
  # services.printing.enable = true;

  # Enable sound.
  # sound.enable = true;
  # hardware.pulseaudio.enable = true;

  # Enable touchpad support (enabled default in most desktopManager).
  # services.xserver.libinput.enable = true;

  sops = {
    defaultSopsFile = ./secrets.yml;
    age = {
      keyFile = ./key.txt;
      generateKey = false;
    };
  };

  # Define a user account. Don't forget to set a password with ‘passwd’.
  # users.users.alice = {
  #   isNormalUser = true;
  #   extraGroups = [ "wheel" ]; # Enable ‘sudo’ for the user.
  #   packages = with pkgs; [
  #     firefox
  #     tree
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

  nixpkgs.config.allowUnfreePredicate = pkg: builtins.elem (lib.getName pkg) [
    "1password-cli"
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
    settings.PermitRootLogin = "no";
    # BEGIN ANSIBLE MANAGED BLOCK SSH PORT
    ports = [ (import ./connection-parameters.nix).ssh_port ];
    # END ANSIBLE MANAGED BLOCK SSH PORT
  };

  # Open ports in the firewall.
  # networking.firewall.allowedTCPPorts = [ ... ];
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

  # This option defines the first version of NixOS you have installed on this particular machine,
  # and is used to maintain compatibility with application data (e.g. databases) created on older NixOS versions.
  #
  # Most users should NEVER change this value after the initial install, for any reason,
  # even if you've upgraded your system to a new NixOS release.
  #
  # This value does NOT affect the Nixpkgs version your packages and OS are pulled from,
  # so changing it will NOT upgrade your system.
  #
  # This value being lower than the current NixOS release does NOT mean your system is
  # out of date, out of support, or vulnerable.
  #
  # Do NOT change this value unless you have manually inspected all the changes it would make to your configuration,
  # and migrated your data accordingly.
  #
  # For more information, see `man configuration.nix` or https://nixos.org/manual/nixos/stable/options#opt-system.stateVersion .
  system.stateVersion = "23.11"; # Did you read the comment?

}

