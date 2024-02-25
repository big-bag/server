{ config, pkgs, ... }:

let
  IP_ADDRESS = (import ./connection-parameters.nix).ip_address;
  SPICE_PORT = "5900";
  WEBSOCKIFY_PORT = "8900";
  DOMAIN_NAME_INTERNAL = (import ./connection-parameters.nix).domain_name_internal;
in

{
  systemd.services = {
    windows = {
      after = [ "libvirtd.service" ];
      requires = [ "libvirtd.service" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = "yes";
      };
      environment = {
        VM_NAME = "windows";
      };
      preStart = let
        agent_config_yaml = pkgs.writeTextFile {
          name = "agent-config.yaml";
          text = ''
            integrations:
              agent:
                enabled: true
                scrape_integration: true
                scrape_interval: 1m
                scrape_timeout: 10s
                metric_relabel_configs:
                  - source_labels: [ __name__ ]
                    regex: (go_.*)
                    action: keep
              windows_exporter:
                enabled: true
                scrape_integration: true
                scrape_interval: 1m
                scrape_timeout: 10s
                enabled_collectors: "cpu,cs,logical_disk,net,os"
                logical_disk:
                  whitelist: "C:"
                  blacklist: "HarddiskVolume.+"
              blackbox:
                enabled: true
                scrape_integration: true
                scrape_interval: 1m
                scrape_timeout: 10s
                blackbox_config:
                  modules:
                    grafana_agent_ready_probe:
                      prober: http
                      timeout: 5s
                      http:
                        valid_status_codes: [ 200 ]
                        valid_http_versions: [ "HTTP/1.1" ]
                        method: GET
                        follow_redirects: false
                        fail_if_body_not_matches_regexp: [ "Agent is Ready." ]
                        enable_http2: false
                        preferred_ip_protocol: ip4
                    grafana_agent_healthy_probe:
                      prober: http
                      timeout: 5s
                      http:
                        valid_status_codes: [ 200 ]
                        valid_http_versions: [ "HTTP/1.1" ]
                        method: GET
                        follow_redirects: false
                        fail_if_body_not_matches_regexp: [ "Agent is Healthy." ]
                        enable_http2: false
                        preferred_ip_protocol: ip4
                    grafana_agent_tcp_probe:
                      prober: tcp
                      timeout: 5s
                      tcp:
                        preferred_ip_protocol: ip4
                        source_ip_address: 127.0.0.1
                    windows_rdp_probe:
                      prober: tcp
                      timeout: 5s
                      tcp:
                        preferred_ip_protocol: ip4
                        source_ip_address: 127.0.0.1
                blackbox_targets:
                  - name: grafana-agent-ready
                    address: http://127.0.0.1:12345/-/ready
                    module: grafana_agent_ready_probe
                  - name: grafana-agent-healthy
                    address: http://127.0.0.1:12345/-/healthy
                    module: grafana_agent_healthy_probe
                  - name: grafana-agent-tcp
                    address: 127.0.0.1:12346
                    module: grafana_agent_tcp_probe
                  - name: windows-rdp
                    address: 127.0.0.1:3389
                    module: windows_rdp_probe
              prometheus_remote_write:
                - url: http://${IP_ADDRESS}:9009/mimir/api/v1/push
          '';
        };
      in ''
        ${pkgs.coreutils}/bin/mkdir -p /mnt/hdd/libvirt/{images,shares}

        ${pkgs.coreutils}/bin/mkdir -p /mnt/hdd/libvirt/images
        if ! [ -f /mnt/hdd/libvirt/images/$VM_NAME.raw ]; then
          ${pkgs.qemu}/bin/qemu-img create -f raw -o preallocation=full /mnt/hdd/libvirt/images/$VM_NAME.raw 100G
          ${pkgs.qemu}/bin/qemu-img info /mnt/hdd/libvirt/images/$VM_NAME.raw
        fi

        ${pkgs.wget}/bin/wget \
          --quiet \
          --timestamping \
          --directory-prefix=/mnt/hdd/libvirt/iso \
          https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/stable-virtio/virtio-win.iso

        ${pkgs.wget}/bin/wget \
          --quiet \
          --timestamping \
          --directory-prefix=/mnt/hdd/libvirt/shares \
          https://www.spice-space.org/download/windows/spice-guest-tools/spice-guest-tools-latest.exe

        ${pkgs.wget}/bin/wget \
          --quiet \
          --timestamping \
          --directory-prefix=/mnt/hdd/libvirt/shares \
          https://github.com/grafana/agent/releases/download/v0.39.2/grafana-agent-installer.exe.zip
        ${pkgs.unzip}/bin/unzip \
          -u \
          /mnt/hdd/libvirt/shares/grafana-agent-installer.exe.zip \
          -d /mnt/hdd/libvirt/shares
        ${pkgs.coreutils}/bin/cat ${agent_config_yaml} > /mnt/hdd/libvirt/shares/agent-config.yaml
      '';
      script = let
        domain_xml = pkgs.writeTextFile {
          name = "domain.xml";
          text = ''
            <domain type="kvm">
              <name>$VM_NAME</name>
              <uuid>$VM_UUID</uuid>
              <metadata>
                <libosinfo:libosinfo xmlns:libosinfo="http://libosinfo.org/xmlns/libvirt/domain/1.0">
                  <libosinfo:os id="http://microsoft.com/win/10"/>
                </libosinfo:libosinfo>
              </metadata>
              <maxMemory unit='GiB'>4</maxMemory>
              <memory unit='GiB'>4</memory>
              <currentMemory unit='GiB'>4</currentMemory>
              <memoryBacking>
                <source type="memfd"/>
                <access mode="shared"/>
              </memoryBacking>
              <vcpu>1</vcpu>
              <os>
                <type arch="x86_64" machine="q35">hvm</type>
                <boot dev="cdrom"/>
                <boot dev="hd"/>
              </os>
              <features>
                <acpi/>
                <apic/>
                <hyperv>
                  <relaxed state="on"/>
                  <vapic state="on"/>
                  <spinlocks state="on" retries="8191"/>
                </hyperv>
                <vmport state="off"/>
              </features>
              <cpu mode="host-passthrough"/>
              <clock offset="localtime">
                <timer name="rtc" tickpolicy="catchup"/>
                <timer name="pit" tickpolicy="delay"/>
                <timer name="hpet" present="no"/>
                <timer name="hypervclock" present="yes"/>
              </clock>
              <on_poweroff>destroy</on_poweroff>
              <on_reboot>restart</on_reboot>
              <on_crash>restart</on_crash>
              <pm>
                <suspend-to-mem enabled="yes"/>
                <suspend-to-disk enabled="yes"/>
              </pm>
              <devices>
                <emulator>/run/libvirt/nix-emulators/qemu-system-x86_64</emulator>
                <disk type="file" device="disk">
                  <driver name="qemu" type="raw"/>
                  <source file="/mnt/hdd/libvirt/images/$VM_NAME.raw"/>
                  <target dev="sda" bus="sata"/>
                </disk>
                <disk type="file" device="cdrom">
                  <driver name="qemu" type="raw"/>
                  <source file="/mnt/hdd/libvirt/iso/CCSA_X64FRE_RU-RU_DV5.iso"/>
                  <target dev="sdb" bus="sata"/>
                  <readonly/>
                </disk>
                <disk type="file" device="cdrom">
                  <driver name="qemu" type="raw"/>
                  <source file="/mnt/hdd/libvirt/iso/virtio-win.iso"/>
                  <target dev="sdc" bus="sata"/>
                  <readonly/>
                </disk>
                <controller type="usb" model="qemu-xhci" ports="15"/>
                <interface type="bridge">
                  <source bridge="br0"/>
                  <target dev="tun0"/>
                  <mac address="$VM_MAC_ADDRESS"/>
                  <model type="e1000e"/>
                </interface>
                <console type="pty"/>
                <channel type="spicevmc">
                  <target type="virtio" name="com.redhat.spice.0"/>
                </channel>
                <channel type='unix'>
                  <source mode='bind' path='/var/lib/libvirt/qemu/f16x86_64.agent'/>
                  <target type='virtio' name='org.qemu.guest_agent.0'/>
                </channel>
                <input type="tablet" bus="usb"/>
                <graphics type="spice" port="${SPICE_PORT}" autoport="no" keymap="us" defaultMode="insecure">
                  <image compression="auto_glz"/>
                  <jpeg compression="auto"/>
                  <zlib compression="auto"/>
                  <playback compression="on"/>
                  <listen type="address" address="127.0.0.1"/>
                </graphics>
                <sound model="ich9"/>
                <video>
                  <model type="qxl"/>
                </video>
                <redirdev bus="usb" type="spicevmc"/>
                <filesystem type='mount' accessmode='passthrough'>
                  <driver type='virtiofs' queue='1024'/>
                  <binary path='${pkgs.virtiofsd}/bin/virtiofsd'/>
                  <source dir='/mnt/hdd/libvirt/shares'/>
                  <target dir='host-share'/>
                  <address type="pci" domain="0x0000" bus="0x06" slot="0x00" function="0x0"/>
                </filesystem>
              </devices>
            </domain>
          '';
        };
      in ''
        set +e

        export VM_UUID=$(${pkgs.util-linux}/bin/uuidgen --sha1 --namespace @dns --name $VM_NAME)
        export VM_MAC_ADDRESS=52:54:00:$(
          ${pkgs.coreutils}/bin/echo $VM_NAME |
          ${pkgs.coreutils}/bin/sha1sum |
          ${pkgs.gnused}/bin/sed "s/^\(..\)\(..\)\(..\).*$/\1:\2:\3/" |
          ${pkgs.gawk}/bin/awk '{print toupper($0)}'
        )

        ${pkgs.libvirt}/bin/virsh define <(${pkgs.envsubst}/bin/envsubst $VM_NAME, $VM_UUID, $VM_MAC_ADDRESS < ${domain_xml}) --validate

        ${pkgs.libvirt}/bin/virsh list --name --state-running | ${pkgs.gnugrep}/bin/grep --word-regexp $VM_NAME > /dev/null
        if [ $? == 1 ]
        then
          ${pkgs.libvirt}/bin/virsh start $VM_NAME
        fi
      '';
      preStop = ''
        set +e

        ${pkgs.libvirt}/bin/virsh list --name --state-shutoff | ${pkgs.gnugrep}/bin/grep --word-regexp $VM_NAME > /dev/null
        if [ $? == 1 ]
        then
          ${pkgs.libvirt}/bin/virsh shutdown $VM_NAME --mode acpi

          time_seconds_start=$(${pkgs.coreutils}/bin/date +%s)
          while ! ${pkgs.libvirt}/bin/virsh list --name --state-shutoff | ${pkgs.gnugrep}/bin/grep --word-regexp $VM_NAME > /dev/null
          do
            time_seconds_now=$(${pkgs.coreutils}/bin/date +%s)
            if [ $((time_seconds_now - time_seconds_start)) -ge 60 ]
            then
              ${pkgs.libvirt}/bin/virsh destroy $VM_NAME
            fi
            ${pkgs.coreutils}/bin/sleep 2
          done
        fi
      '';
      wantedBy = [ "multi-user.target" ];
    };
  };

  environment = {
    systemPackages = with pkgs; [
      (pkgs.callPackage derivations/websockify.nix {})
    ];
  };

  systemd.services = {
    windows-websockify = {
      after = [
        "nginx-prepare.service"
        "windows.service"
      ];
      before = [ "nginx.service" ];
      serviceConfig = {
        Type = "simple";
        ExecStart = ''
          /run/current-system/sw/bin/websockify \
            --verbose \
            --cert=/mnt/ssd/services/nginx/server.crt \
            --key=/mnt/ssd/services/nginx/server.key \
            --ssl-only \
            --verify-client \
            --cafile=/mnt/ssd/services/nginx/ca.pem \
            --ssl-version=tlsv1_3 \
            ${IP_ADDRESS}:${WEBSOCKIFY_PORT} \
            127.0.0.1:${SPICE_PORT}
        '';
        Restart = "always";
        CPUQuota = "1%";
        MemoryHigh = "61M";
        MemoryMax = "64M";
      };
      wantedBy = [
        "nginx-prepare.service"
        "windows.service"
        "nginx.service"
      ];
    };
  };

  networking = {
    firewall = {
      allowedTCPPorts = [ 8900 ];
    };
  };

  environment = {
    etc = {
      "spice-web-client/windows" = {
        source = pkgs.runCommandLocal "windows" {
          src = pkgs.fetchgit {
            url = "https://github.com/eyeos/spice-web-client.git";
            rev = (import ./variables.nix).spice_web_client_commit_id;
            hash = (import ./variables.nix).spice_web_client_commit_hash;
          };
        } ''
          mkdir $out
          sed "s/('host') || '.*',/('host') || '${DOMAIN_NAME_INTERNAL}',/g;
               s/('port') || .*,/('port') || ${WEBSOCKIFY_PORT},/g;
               s/('protocol') || '.*',/('protocol') || 'wss',/g
              " $src/run.js > $out/run.js
          ${pkgs.rsync}/bin/rsync --archive --exclude='run.js' $src/ $out
        '';
      };
    };
  };

  sops.secrets = {
    "windows/nginx/file/basic_auth" = {
      mode = "0400";
      owner = config.services.nginx.user;
      group = config.services.nginx.group;
    };
  };

  services = {
    nginx = {
      virtualHosts.${DOMAIN_NAME_INTERNAL} = {
        locations."/windows" = {
          extraConfig = ''
            if ($ssl_client_verify != "SUCCESS") {
              return 496;
            }
          '';
          basicAuthFile = config.sops.secrets."windows/nginx/file/basic_auth".path;

          root = "/etc/spice-web-client";
          index = "index.html";
        };
      };
    };
  };

  sops.secrets = {
    "1password/application/envs" = {
      mode = "0400";
      owner = config.users.users.root.name;
      group = config.users.users.root.group;
    };
  };

  sops.secrets = {
    "windows/nginx/envs" = {
      mode = "0400";
      owner = config.users.users.root.name;
      group = config.users.users.root.group;
    };
  };

  systemd.services = {
    windows-1password = {
      after = [
        "windows.service"
        "windows-websockify.service"
      ];
      preStart = "${pkgs.coreutils}/bin/sleep $((RANDOM % ${(import ./variables.nix).one_password_max_delay}))";
      serviceConfig = {
        Type = "oneshot";
        EnvironmentFile = [
          config.sops.secrets."1password/application/envs".path
          config.sops.secrets."windows/nginx/envs".path
        ];
      };
      environment = {
        OP_CONFIG_DIR = "/root/.config/op";
      };
      script = ''
        set +e

        SESSION_TOKEN=$(echo "$OP_MASTER_PASSWORD" | ${pkgs._1password}/bin/op account add \
          --address $OP_SUBDOMAIN.1password.com \
          --email $OP_EMAIL_ADDRESS \
          --secret-key $OP_SECRET_KEY \
          --signin --raw)

        ${pkgs._1password}/bin/op item get Windows \
          --vault Server \
          --session $SESSION_TOKEN > /dev/null

        if [ $? != 0 ]
        then
          ${pkgs._1password}/bin/op item template get Login --session $SESSION_TOKEN | ${pkgs._1password}/bin/op item create --vault Server - \
            --title Windows \
            --url https://${DOMAIN_NAME_INTERNAL}/windows \
            username=$NGINX_USERNAME \
            password=$NGINX_PASSWORD \
            --session $SESSION_TOKEN > /dev/null
          ${pkgs.coreutils}/bin/echo "Item created successfully."
        else
          ${pkgs._1password}/bin/op item edit Windows \
            --vault Server \
            --url https://${DOMAIN_NAME_INTERNAL}/windows \
            username=$NGINX_USERNAME \
            password=$NGINX_PASSWORD \
            --session $SESSION_TOKEN > /dev/null
          ${pkgs.coreutils}/bin/echo "Item updated successfully."
        fi
      '';
      wantedBy = [
        "windows.service"
        "windows-websockify.service"
      ];
    };
  };

  services = {
    grafana-agent = {
      settings = {
        logs = {
          configs = [{
            name = "windows";
            clients = [{
              url = "http://${config.services.loki.configuration.server.http_listen_address}:${toString config.services.loki.configuration.server.http_listen_port}/loki/api/v1/push";
            }];
            positions = {
              filename = "\${STATE_DIRECTORY}/positions/windows.yml";
            };
            scrape_configs = [{
              job_name = "journal";
              journal = {
                json = false;
                max_age = "12h";
                labels = {
                  systemd_job = "systemd-journal";
                };
                path = "/var/log/journal";
              };
              relabel_configs = [
                {
                  source_labels = [ "__journal__systemd_unit" ];
                  regex = "(windows|windows-websockify|windows-1password).service";
                  action = "keep";
                }
                {
                  source_labels = [ "__journal__systemd_unit" ];
                  target_label = "systemd_unit";
                  action = "replace";
                }
              ];
            }];
          }];
        };
      };
    };
  };
}
