# Setting up a local environment and preparing a server

Build an image
```fish
docker build --rm --file Dockerfile --tag ansible:2.14.0 .
```

Create a Vault password file named `.vault_password` and add a password into it

Create encrypted file
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

Write a username for a technical account into a variable `vault_tech_account_name`

Run a playbook to do an initial configuration on a server and configure a local environment
```fish
docker run --rm -t \
  --volume=(pwd):/etc/ansible \
  ansible:2.14.0 \
    ansible-playbook prepare.yml
```
