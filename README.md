# Setting up environment

Build image
```fish
docker build --rm --file Dockerfile --tag ansible:2.14.0 .
```

# Prepare server

Create Vault password file named `.vault_password` and add password into it

Create encrypted file
```fish
docker run --rm -ti \
    --volume=(pwd):/etc/ansible \
    ansible:2.14.0 \
        ansible-vault create host_vars/localhost/vault.yml
```

Write creadentials to access 1Password into variables:
  - `vault_1password_device_id: <value>` - value can be found in `~/.config/op/config` on Alpine linux
  - `vault_1password_master_password: 'S0me P@ssword'`
  - `vault_1password_subdomain: my`
  - `vault_1password_email_address: email@example.com`
  - `vault_1password_secret_key: <value>`

Command to edit encrypted file
```fish
docker run --rm -ti \
    --volume=(pwd):/etc/ansible \
    ansible:2.14.0 \
        ansible-vault edit host_vars/localhost/vault.yml
```

Run playbook to make initial configuration on server
```fish
docker run --rm -t \
    --volume=(pwd):/etc/ansible \
    ansible:2.14.0 \
        ansible-playbook prepare.yml
```
