# Installing NixOS

<details>
<summary>Server specification</summary>
<br>

| Hardware | Configuration |
| :--- | :--- |
| Processor | Intel Core i7-4790, 4x3600 MHz |
| Memory | 32 GB DDR3 1600 MHz |
| Disks | 120 GB SSD x 2, 4 TB HDD x 1 |

</details>

<details>
<summary>Boot from installation ISO image</summary>
<br>

Boot from installation ISO image (Minimal, 64-bit Intel/AMD):

1. set a password for the `nixos` user
   ```bash
   passwd
   ```

2. connect from a remote host
   ```bash
   ssh nixos@[SERVER_IP_ADDRESS]
   ```

</details>

<details>
<summary>Partitioning of disk</summary>
<br>

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

</details>

<details>
<summary>Formatting of disk</summary>
<br>

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

</details>

<details>
<summary>Installing OS</summary>
<br>

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
     settings.PermitRootLogin = "yes";
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

</details>

# Setting up a local environment and preparing a server

<details>
<summary>Prepare</summary>
<br>

1. build an image
   ```bash
   docker build --rm --file Dockerfile --tag ansible:2.15.1 .
   ```

2. create a Vault password file named `.vault_password` and add a password in it

3. create an encrypted file
   ```bash
   docker run --rm -ti \
     --volume=$(pwd):/etc/ansible \
     ansible:2.15.1 \
       ansible-vault create host_vars/localhost/vault.yml
   ```

4. write credentials to encrypted file
   ```bash
   ---
   vault_server_ip_address: 192.168.0.1
   vault_server_root_account_password: 'S0me P@ssword'
   vault_server_technical_account_username: [VALUE]

   vault_1password_device_id: [VALUE] (can be found in `~/.config/op/config` on Alpine linux)
   vault_1password_master_password: 'S0me P@ssword'
   vault_1password_subdomain: my
   vault_1password_email_address: email@example.com
   vault_1password_secret_key: [VALUE]

   vault_domain_name_internal: example.com

   vault_pgadmin_postgres_username: [VALUE]
   vault_grafana_agent_postgres_username: [VALUE]
   vault_grafana_agent_redis_username: [VALUE]

   vault_mattermost_postgres_username: [VALUE]
   vault_mattermost_postgres_database: [VALUE]

   vault_gitlab_postgres_username: [VALUE]
   vault_gitlab_postgres_database: [VALUE]
   ```

5. run a playbook to do an initial configuration on a server and configure a local environment
   ```bash
   docker run --rm -t \
     --volume=$(pwd):/etc/ansible \
     ansible:2.15.1 \
       ansible-playbook site.yml --tags prepare
   ```

6. run a playbook to create secrets
   ```bash
   docker run --rm -t \
     --volume=$(pwd):/etc/ansible \
     ansible:2.15.1 \
       ansible-playbook site.yml --tags secrets
   ```

7. run a playbook to upload grafana dashboards
   ```bash
   docker run --rm -t \
     --volume=$(pwd):/etc/ansible \
     ansible:2.15.1 \
       ansible-playbook site.yml --tags dashboards
   ```

8. grafana dashboard sources

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

9. run a playbook to upgrade NixOS and services to the latest version
   ```bash
   docker run --rm -ti \
     --volume=$(pwd):/etc/ansible \
     ansible:2.15.1 \
       ansible-playbook site.yml --tags upgrade
   ```

</details>

# Configuring a server

<details>
<summary>Deploy</summary>
<br>

1. run a playbook to configure a server
   ```bash
   docker run --rm -t \
     --volume=$(pwd):/etc/ansible \
     ansible:2.15.1 \
       ansible-playbook site.yml
   ```

2. import certificates in Firefox: Preferences -> Privacy & Security -> Security -> Certificates -> View Certificates...
   * import certificate authority: Authorities -> Import... -> ca.pem (choose `Trust this CA to identify websites.`)
   * import user certificate for authentication: Your Certificates -> Import... -> user.pfx (leave the password field blank and click Log in)

</details>
