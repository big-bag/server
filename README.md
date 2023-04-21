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

1. delete data from SSD drives
   ```bash
   sudo shred --verbose /dev/sdX
   ```

2. find disk which connected to SATA-port 1
   ```bash
   $ for i in /dev/disk/by-path/*;do [[ ! "$i" =~ '-part[0-9]+$' ]] && echo "Port $(basename "$i"|grep -Po '(?<=ata-)[0-9]+'): $(readlink -f "$i")";done
   Port 1: /dev/sdb
   ```

3. create a GPT partition table
   ```bash
   sudo parted /dev/sdb -- mklabel gpt
   ```

4. create a `root` partition, left 16GiB for `swap` partition at the end of disk and 512MiB for `boot` partition at the beggining of disk
   ```bash
   sudo parted /dev/sdb -- mkpart primary 512MiB -16GiB
   ```

5. create a `swap` partition
   ```bash
   sudo parted -a none /dev/sdb -- mkpart primary linux-swap -16GiB 100%
   ```

6. create a `boot` partition
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

9. delete data from HDD drive
   * run the process in the background, because it can take a long time
     ```bash
     sudo shred --verbose /dev/sdX >> shred.log 2>&1 &
     ```
   * display logs
     ```bash
     tail -f shred.log
     ```

# Setting up a local environment and preparing a server

1. save secrets in 1Password
   * vault: `Local server`
     * item: `Secrets (manually)`
       * section: `Server`
         * ip address[text]: [SERVER_IP_ADDRESS]
       * section: `Root account`
         * username[text]: root
         * password[password]: [ROOT_USER_PASSWORD]
       * section: `Technical account`
         * nixos[text]: [NIXOS_TECHNICAL_ACCOUNT]
         * postgres pgadmin username[text]: [PGADMIN_POSTGRES_USER]
         * postgres monitoring username[text]: [MONITORING_POSTGRES_USER]
         * redis monitoring username[text]: [MONITORING_REDIS_USER]
         * postgres gitlab username[text]: [GITLAB_POSTGRES_USER]
       * section: `Domains`
         * internal domain name[text]: example.com

2. build an image
   ```bash
   docker build --rm --file Dockerfile --tag ansible:2.14.2 .
   ```

3. create a Vault password file named `.vault_password` and add a password in it

4. create an encrypted file
   ```bash
   docker run --rm -ti \
     --volume=$(pwd):/etc/ansible \
     ansible:2.14.2 \
       ansible-vault create host_vars/localhost/vault.yml
   ```

5. write credentials to access 1Password in variables:
   - vault_1password_device_id: `<value>`, value can be found in `~/.config/op/config` on Alpine linux
   - vault_1password_master_password: `'S0me P@ssword'`
   - vault_1password_subdomain: `my`
   - vault_1password_email_address: `email@example.com`
   - vault_1password_secret_key: `<value>`

6. run a playbook to do an initial configuration on a server and configure a local environment
   ```bash
   docker run --rm -t \
     --volume=$(pwd):/etc/ansible \
     ansible:2.14.2 \
       ansible-playbook prepare.yml
   ```

7. run a playbook to upgrade NixOS to the latest version
   ```bash
   docker run --rm -t \
     --volume=$(pwd):/etc/ansible \
     ansible:2.14.2 \
       ansible-playbook prepare.yml --tags upgrade
   ```

# Configuring a server

1. run a playbook to upload grafana dashboards
   ```bash
   docker run --rm -t \
     --volume=$(pwd):/etc/ansible \
     ansible:2.14.2 \
       ansible-playbook site.yml --tags dashboards
   ```

2. run a playbook to configure a server
   ```bash
   docker run --rm -t \
     --volume=$(pwd):/etc/ansible \
     ansible:2.14.2 \
       ansible-playbook site.yml
   ```

3. import certificate authority in browser

   For example in Firefox: Preferences -> Privacy & Security -> Security -> Certificates -> View Certificates... -> Authorities -> Import... -> ca.crt (choose `Trust this CA to identify websites.`)

4. grafana dashboard sources

   | Dashboard name/group | Dashboard source (based on) |
   | :--- | :--- |
   | MinIO Dashboard | https://grafana.com/grafana/dashboards/13502-minio-dashboard/ |
   | Mimir | https://grafana.com/grafana/dashboards/16007-mimir-alertmanager/ |
   || https://grafana.com/grafana/dashboards/16009-mimir-compactor/ |
   || https://grafana.com/grafana/dashboards/16011-mimir-object-store/ |
   || https://grafana.com/grafana/dashboards/16012-mimir-overrides/ |
   || https://grafana.com/grafana/dashboards/16013-mimir-queries/ |
   || https://grafana.com/grafana/dashboards/16016-mimir-reads/ |
   || https://grafana.com/grafana/dashboards/16018-mimir-ruler/ |
   || https://grafana.com/grafana/dashboards/16021-mimir-tenants/ |
   || https://grafana.com/grafana/dashboards/16022-mimir-top-tenants/ |
   || https://grafana.com/grafana/dashboards/16026-mimir-writes/ |
   | Prometheus | Configuration -> Data Sources -> Prometheus -> Dashboards -> Prometheus Stats |
   || Configuration -> Data Sources -> Prometheus -> Dashboards -> Prometheus 2.0 Stats |
   | Grafana metrics | Configuration -> Data Sources -> Prometheus -> Dashboards -> Grafana metrics |
   | Node Exporter Dashboard | https://grafana.com/grafana/dashboards/13978-node-exporter-quickstart-and-dashboard/ |
   || https://grafana.com/grafana/dashboards/6014-host-stats-0-16-0/ |
   | PostgreSQL Exporter Dashboard | https://grafana.com/grafana/dashboards/14114-postgres-overview/ |
   | Redis Exporter Dashboard | https://grafana.com/grafana/dashboards/14091-redis-dashboard-for-prometheus-redis-exporter-1-x/ |
   | GitLab | https://gitlab.com/gitlab-org/grafana-dashboards/-/blob/master/omnibus/gitaly.json |
   || https://gitlab.com/gitlab-org/grafana-dashboards/-/blob/master/omnibus/overview.json |
   || https://gitlab.com/gitlab-org/grafana-dashboards/-/blob/master/omnibus/postgresql.json |
   || https://gitlab.com/gitlab-org/grafana-dashboards/-/blob/master/omnibus/rails-app.json |
   || https://gitlab.com/gitlab-org/grafana-dashboards/-/blob/master/omnibus/redis.json |
   || https://gitlab.com/gitlab-org/grafana-dashboards/-/blob/master/omnibus/registry.json |
   || https://gitlab.com/gitlab-org/grafana-dashboards/-/blob/master/omnibus/service_platform_metrics.json |
