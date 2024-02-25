{ config, pkgs, ... }:

let
  DOMAIN_NAME_INTERNAL = (import ./connection-parameters.nix).domain_name_internal;
in

{
  security = {
    dhparams = {
      enable = true;
      path = "/mnt/ssd/services/dhparams";
      defaultBitSize = 4096;
      params = {
        nginx = {};
      };
    };
  };

  systemd.services = {
    nginx-prepare = {
      before = [ "nginx.service" ];
      serviceConfig = {
        Type = "oneshot";
      };
      environment = {
        DOMAIN_NAME_INTERNAL = "${DOMAIN_NAME_INTERNAL}";
      };
      script = let
        ca_cnf = pkgs.writeTextFile {
          name = "ca.cnf.template";
          text = ''
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
            organizationName    = $ORGANIZATION_NAME, Ltd.
            commonName          = $COMMON_NAME-ca

            [v3_req]
            basicConstraints     = critical, CA:true
            keyUsage             = critical, keyCertSign, cRLSign
            subjectKeyIdentifier = hash
          '';
        };
        ca_intermediate_cnf = pkgs.writeTextFile {
          name = "ca-intermediate.cnf.template";
          text = ''
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
            organizationName    = $ORGANIZATION_NAME, Ltd.
            commonName          = $COMMON_NAME-int-ca

            [v3_req]
            basicConstraints     = critical, CA:true
            keyUsage             = critical, keyCertSign, cRLSign
            subjectKeyIdentifier = hash
          '';
        };
        server_cnf = pkgs.writeTextFile {
          name = "server.cnf.template";
          text = ''
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
            organizationName    = $ORGANIZATION_NAME, Ltd.
            commonName          = $DOMAIN_NAME_INTERNAL

            [v3_req]
            basicConstraints = CA:FALSE
            keyUsage         = nonRepudiation, digitalSignature, keyEncipherment, keyAgreement
            extendedKeyUsage = critical, serverAuth
            subjectAltName   = @alt_names

            [alt_names]
            DNS.1 = $DOMAIN_NAME_INTERNAL
            DNS.2 = gitlab.$DOMAIN_NAME_INTERNAL
            DNS.3 = registry.$DOMAIN_NAME_INTERNAL
            DNS.4 = pages.$DOMAIN_NAME_INTERNAL
          '';
        };
        user_cnf = pkgs.writeTextFile {
          name = "user.cnf.template";
          text = ''
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
            organizationName    = $ORGANIZATION_NAME, Ltd.
            commonName          = user.$DOMAIN_NAME_INTERNAL

            [v3_req]
            basicConstraints = CA:FALSE
            keyUsage         = nonRepudiation, digitalSignature, keyEncipherment, keyAgreement
            extendedKeyUsage = critical, clientAuth
          '';
        };
      in ''
        ${pkgs.coreutils}/bin/mkdir -p /mnt/ssd/services/{ca,nginx}
        ${pkgs.coreutils}/bin/mkdir -p /tmp/nginx_client_body

        cd /mnt/ssd/services/ca

        export ORGANIZATION_NAME=$(${pkgs.coreutils}/bin/echo $DOMAIN_NAME_INTERNAL | ${pkgs.gnused}/bin/sed 's/\./ /g' | ${pkgs.gawk}/bin/awk '{for(i=1;i<=NF;i++){ $i=toupper(substr($i,1,1)) substr($i,2) }}1')
        export COMMON_NAME=$(${pkgs.coreutils}/bin/echo $DOMAIN_NAME_INTERNAL | ${pkgs.gnused}/bin/sed 's/\./-/g')

        if ! [ -f ca.crt ]; then
          ${pkgs.coreutils}/bin/echo "Creating Self-Signed Root CA certificate and key."
          ${pkgs.envsubst}/bin/envsubst $ORGANIZATION_NAME, $COMMON_NAME < ${ca_cnf} > ca.cnf
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
          ${pkgs.coreutils}/bin/echo "Creating Intermediate CA certificate and key."
          ${pkgs.envsubst}/bin/envsubst $ORGANIZATION_NAME, $COMMON_NAME < ${ca_intermediate_cnf} > ca-intermediate.cnf
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
          ${pkgs.coreutils}/bin/echo "Creating CA chain."
          ${pkgs.coreutils}/bin/cat ca_int.crt ca.crt > ca.pem
        fi

        if ! [ -f server.crt ]; then
          ${pkgs.coreutils}/bin/echo "Creating server (Nginx) certificate and key."
          ${pkgs.envsubst}/bin/envsubst $ORGANIZATION_NAME, $DOMAIN_NAME_INTERNAL < ${server_cnf} > server.cnf
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
          ${pkgs.coreutils}/bin/echo "Creating user certificate and key."
          ${pkgs.envsubst}/bin/envsubst $ORGANIZATION_NAME, $DOMAIN_NAME_INTERNAL < ${user_cnf} > user.cnf
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

  # generated 2023-09-18, Mozilla Guideline v5.7, nginx 1.24.0, OpenSSL 3.0.10, modern configuration
  # https://ssl-config.mozilla.org/#server=nginx&version=1.24.0&config=modern&openssl=3.0.10&guideline=5.7
  services = {
    nginx = {
      enable = true;

      user = "nginx";
      group = "nginx";

      appendHttpConfig = "client_body_temp_path /tmp/nginx_client_body 1 2;";

      sslProtocols = "TLSv1.3";
      sslCiphers = null;
      sslDhparam = "${config.security.dhparams.path}/nginx.pem";

      statusPage = true;

      virtualHosts.${DOMAIN_NAME_INTERNAL} = let
        IP_ADDRESS = (import ./connection-parameters.nix).ip_address;
      in {
        listen = [
          { addr = "${IP_ADDRESS}"; port = 80; }
          { addr = "${IP_ADDRESS}"; port = 443; ssl = true; }
        ];

        http2 = true;
        kTLS = true;
        forceSSL = true;
        sslCertificate = "/mnt/ssd/services/nginx/server.crt";
        sslCertificateKey = "/mnt/ssd/services/nginx/server.key";
        # verify chain of trust of OCSP response using Root CA and Intermediate certs
        sslTrustedCertificate = "/mnt/ssd/services/nginx/ca.pem";

        extraConfig = ''
          access_log /var/log/nginx/access.log;
          error_log /var/log/nginx/error.log;

          ssl_session_timeout 1d;
          ssl_session_cache shared:MozSSL:10m; # about 40000 sessions
          ssl_session_tickets off;

          ssl_prefer_server_ciphers off;

          # HSTS (ngx_http_headers_module is required) (63072000 seconds = two years)
          add_header Strict-Transport-Security "max-age=63072000" always;

          # OCSP stapling
          # fetch OCSP records from URL in ssl_certificate and cache them
          ssl_stapling on;
          ssl_stapling_verify on;

          # Enable TLSv1.3's 0-RTT
          # Use $ssl_early_data when reverse proxying to prevent replay attacks
          # https://nginx.org/en/docs/http/ngx_http_ssl_module.html#ssl_early_data
          ssl_early_data on;

          # Authentication based on a client certificate
          ssl_client_certificate /mnt/ssd/services/nginx/ca.pem;
          ssl_verify_client optional;
        '';

        locations."/" = {
          extraConfig = ''
            if ($remote_addr = ${IP_ADDRESS}) {
              proxy_pass http://127.0.0.1;
              break;
            }

            if ($ssl_client_verify != "SUCCESS") {
              return 496;
            }
          '';
        };
      };

      resolver = let
        NAMESERVER = (import ./connection-parameters.nix).nameserver;
      in {
        addresses = ["${NAMESERVER}:53"];
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

  networking.firewall.allowedTCPPorts = [
    80
    443
  ];
}
