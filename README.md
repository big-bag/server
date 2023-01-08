# Installing NixOS

Server specification

| Hardware | Configuration |
| :--- | :--- |
| Processor | Intel Core i7-4790, 4x3600 MHz |
| Memory | 32 GB DDR3 1600 MHz |
| Disks | 120 GB SSD x 2, 4 TB HDD x 1 |

Boot from installation ISO image (Minimal, 64-bit Intel/AMD):

1. set a password for the `nixos` user
   ```bash
   passwd
   ```

2. connect from a remote host
   ```bash
   ssh nixos@[SERVER_IP_ADDRESS]
   ```

Partitioning of disk:

> Ignore info messages from parted: `Information: You may need to update /etc/fstab.`

1. find disk which connected to SATA-port 1
   ```bash
   $ for i in /dev/disk/by-path/*;do [[ ! "$i" =~ '-part[0-9]+$' ]] && echo "Port $(basename "$i"|grep -Po '(?<=ata-)[0-9]+'): $(readlink -f "$i")";done
   Port 1: /dev/sdb
   ```

2. create a GPT partition table
   ```bash
   sudo parted /dev/sdb -- mklabel gpt
   ```

3. create a `root` partition, left 16GiB for `swap` partition at the end of disk and 512MiB for `boot` partition at the beggining of disk
   ```bash
   sudo parted /dev/sdb -- mkpart primary 512MiB -16GiB
   ```

4. create a `swap` partition
   ```bash
   sudo parted -a none /dev/sdb -- mkpart primary linux-swap -16GiB 100%
   ```

5. create a `boot` partition
   ```bash
   sudo parted /dev/sdb -- mkpart ESP fat32 1MiB 512MiB
   sudo parted /dev/sdb -- set 3 esp on
   ```

Formatting of disk:

1. format a `root` partition to ext4, add a label `nixos`
   ```bash
   sudo mkfs.ext4 -L nixos /dev/sdb1
   ```

2. create a `swap` partition, add a label `swap`
   ```bash
   sudo mkswap -L swap /dev/sdb2
   ```

3. create a `boot` partition, add a lable `boot`
   ```bash
   sudo mkfs.fat -F 32 -n boot /dev/sdb3
   ```

Installing OS:

1. mount the target file system on which NixOS should be installed on `/mnt`
   ```bash
   sudo mount /dev/disk/by-label/nixos /mnt
   ```

2. mount the boot file system on `/mnt/boot`
   ```bash
   sudo mkdir -p /mnt/boot
   sudo mount /dev/disk/by-label/boot /mnt/boot
   ```

3. generate an initial configuration file
   ```bash
   sudo nixos-generate-config --root /mnt
   ```

4. edit a configuration file
   ```bash
   sudo nano /mnt/etc/nixos/configuration.nix
   ```
   * enable OpenSSH service
   * allow login as root user
   ```
   services.openssh = {
     enable = true;
     permitRootLogin = "yes";
   };
   ```

5. run the installation
   ```bash
   sudo nixos-install
   ```

6. at the end of the installation set the password for the root user. If something went wrong, set it manually
   ```bash
   [nixos@nixos:~]$ sudo nixos-enter --root '/mnt'
   [root@nixos:/]# passwd
   [root@nixos:/]# exit
   ```

7. reboot system
   ```bash
   sudo reboot
   ```

8. after reboot check connection under the `root` user
   ```bash
   ssh root@[SERVER_IP_ADDRESS]
   ```

9. save credentials into 1Password
   * vault: `Local server`
     * item: `Account root`
       * username[text]: root
       * password[password]: [ROOT_USER_PASSWORD]
       * ip-address[text]: [SERVER_IP_ADDRESS]

# Setting up a local environment and preparing a server

Build an image
```fish
docker build --rm --file Dockerfile --tag ansible:2.14.0 .
```

Create a Vault password file named `.vault_password` and add a password into it

Create an encrypted file
```fish
docker run --rm -ti \
  --volume=(pwd):/etc/ansible \
  ansible:2.14.0 \
    ansible-vault create host_vars/localhost/vault.yml
```

Write credentials to access 1Password into variables:
  - `vault_1password_device_id: <value>` - value can be found in `~/.config/op/config` on Alpine linux
  - `vault_1password_master_password: 'S0me P@ssword'`
  - `vault_1password_subdomain: my`
  - `vault_1password_email_address: email@example.com`
  - `vault_1password_secret_key: <value>`

Write username for a technical account into a variable `vault_technical_account_name`

Run a playbook to do an initial configuration on a server and configure a local environment
```fish
docker run --rm -t \
  --volume=(pwd):/etc/ansible \
  ansible:2.14.0 \
    ansible-playbook prepare.yml
```

Run a playbook to upgrade NixOS to the latest version
```fish
docker run --rm -t \
  --volume=(pwd):/etc/ansible \
  ansible:2.14.0 \
    ansible-playbook prepare.yml --tags upgrade
```

# Configuring a server

Save internal domain name into 1Password
* vault: `Local server`
  * item: `DNS`
    * internal domain name[text]: example.com

Edit an encrypted file
```fish
docker run --rm -ti \
  --volume=(pwd):/etc/ansible \
  ansible:2.14.0 \
    ansible-vault edit host_vars/localhost/vault.yml
```

Write username for a prometheus basic auth user into a variable `vault_prometheus_basic_auth_user`

Write username for a grafana admin user into a variable `vault_grafana_admin_user`

Run a playbook to configure a server
```fish
docker run --rm -t \
  --volume=(pwd):/etc/ansible \
  ansible:2.14.0 \
    ansible-playbook site.yml
```

Import certificate authority in browser

For example in Firefox: Preferences -> Privacy & Security -> Security -> Certificates -> View Certificates... -> Authorities -> Import... -> ca.crt (choose `Trust this CA to identify websites.`)

Grafana dashboard sources

| Dashboard | Source (based on) |
| :--- | :--- |
| Prometheus Stats.json | Configuration -> Data Sources -> Prometheus -> Dashboards -> Prometheus Stats |
| Prometheus 2.0 Stats.json | Configuration -> Data Sources -> Prometheus -> Dashboards -> Prometheus 2.0 Stats |
| Grafana metrics.json | Configuration -> Data Sources -> Prometheus -> Dashboards -> Grafana metrics |
| Node Exporter.json | https://grafana.com/grafana/dashboards/13978-node-exporter-quickstart-and-dashboard/ and https://grafana.com/grafana/dashboards/6014-host-stats-0-16-0/ |
