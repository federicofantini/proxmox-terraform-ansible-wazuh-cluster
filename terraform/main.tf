################################### NGINX #########################################

# Run nginx provisioning (dashboard reverse proxy)
locals {
  nginx_extern_ip   = var.nginx_extern_ip
  vm_ip_by_name     = zipmap(var.hostnames, var.ips)
  dashboard_ip      = local.vm_ip_by_name["wazuh"]
  nginx_local_ip    = local.vm_ip_by_name["nginx"]

  nginx_https_conf = <<-EOF
upstream dashboard_backend {
  server ${local.dashboard_ip}:443;
}

server {
  listen ${local.nginx_extern_ip}:443 ssl http2;
  server_name wazuh-cluster.net;

  ssl_certificate     /etc/nginx/certs/dashboard.crt;
  ssl_certificate_key /etc/nginx/certs/dashboard.key;
  ssl_protocols TLSv1.2 TLSv1.3;

  location / {
    proxy_http_version 1.1;

    proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto $scheme;

    proxy_set_header Upgrade $http_upgrade;
    proxy_set_header Connection "upgrade";

    # backend HTTPS
    proxy_pass https://dashboard_backend;
    proxy_ssl_server_name on;
    proxy_ssl_verify off;

    # timeouts "safe"
    proxy_connect_timeout 30s;
    proxy_read_timeout    300s;
    proxy_send_timeout    300s;
  }
}

# redirect to https
server {
  listen ${local.nginx_extern_ip}:80;
  server_name wazuh-cluster.net;
  return 301 https://$host$request_uri;
}
EOF

  nginx_stream_conf = <<-EOF
upstream wazuh_agent_data {
  server ${local.dashboard_ip}:1514;
}

upstream wazuh_agent_enroll {
  server ${local.dashboard_ip}:1515;
}

server {
  listen ${local.nginx_extern_ip}:1514;
  proxy_pass wazuh_agent_data;
  proxy_timeout 1h;
}

server {
  listen ${local.nginx_extern_ip}:1515;
  proxy_pass wazuh_agent_enroll;
  proxy_timeout 10s;
}
EOF
}

resource "null_resource" "configure_nginx" {
  provisioner "remote-exec" {
    inline = [
      "set -e",

      # Install nginx (just to be sure)
      "sudo apt-get update -y",
      "sudo apt-get install -y nginx openssl libnginx-mod-stream",
      "sudo grep -q '^include /etc/nginx/modules-enabled/\\*\\.conf;' /etc/nginx/nginx.conf || (echo 'ERROR: nginx.conf missing modules-enabled include' >&2; exit 1)",

      # Cert self-signed (if not exists)
      "sudo mkdir -p /etc/nginx/certs",
      "sudo test -f /etc/nginx/certs/dashboard.key -a -f /etc/nginx/certs/dashboard.crt || sudo openssl req -x509 -nodes -newkey rsa:2048 -days 3650 -keyout /etc/nginx/certs/dashboard.key -out /etc/nginx/certs/dashboard.crt -subj '/CN=wazuh-cluster.net'",

      # Write config HTTP
      "sudo tee /etc/nginx/sites-available/dashboard > /dev/null <<'EOF'\n${replace(local.nginx_https_conf, "\r", "")}\nEOF",

      # Enable site
      "sudo rm -f /etc/nginx/sites-enabled/default || true",
      "sudo ln -sf /etc/nginx/sites-available/dashboard /etc/nginx/sites-enabled/dashboard",

      # Write STREAM config
      "sudo mkdir -p /etc/nginx/stream.d",
      "sudo tee /etc/nginx/stream.d/wazuh.conf > /dev/null <<'EOF'\n${replace(local.nginx_stream_conf, "\r", "")}\nEOF",

      # Ensure nginx.conf has a stream block that includes stream.d
      "sudo bash -lc \"grep -qE '^stream[[:space:]]*\\{' /etc/nginx/nginx.conf || sed -i '/^http[[:space:]]*{/i\\stream {\\n  include /etc/nginx/stream.d/*.conf;\\n}\\n' /etc/nginx/nginx.conf\"",

      # Test + reload
      "sudo nginx -t",
      "sudo systemctl enable nginx",
      "sleep 10 && sudo systemctl restart nginx"
    ]

    connection {
      host        = local.nginx_local_ip
      user        = var.user
      private_key = file(var.ssh_keys["priv"])
      agent       = false
      timeout     = "10m"
    }
  }
}





################################### WAZUH #########################################





resource "proxmox_vm_qemu" "prox_vm" {
  # One VM per hostname
  count = length(var.hostnames)

  # Identity
  name        = var.hostnames[count.index]
  vmid        = var.vmid + count.index
  target_node = var.proxmox_host["target_node"]
  clone       = "cloud-init-noble"
  full_clone  = true

  # Pull the per‑VM hardware spec from var.hardware
  cpu {
    cores   = var.hardware[var.hostnames[count.index]].cores
    sockets = var.hardware[var.hostnames[count.index]].sockets
  }
  memory  = var.hardware[var.hostnames[count.index]].memory
  balloon = 0

  # Boot & misc options
  boot    = "c"
  bootdisk = "virtio0"
  scsihw  = "virtio-scsi-pci"

  start_at_node_boot = false
  hotplug = "disk"

  # Networking
  network {
    id     = 0
    bridge = "vmbr0"
    model  = "virtio"
    tag    = var.vlan_tag != null ? var.vlan_tag : null
  }

  dynamic "network" {
    for_each = var.hostnames[count.index] == "nginx" ? [1] : []
    content {
      id     = 1
      bridge = "vmbr0"
      model  = "virtio"
    }
  }

  # Make serial console usable
  serial {
    id   = 0
    type = "socket"
  }
  vga {
    type = "serial0"
  }

  # Cloud‑init IP configuration (CIDR /24). Gateway = first host in the subnet. (no gw vlan for nginx)
  ipconfig0 = var.hostnames[count.index] == "nginx" ? "ip=${var.ips[count.index]}/24" : "ip=${var.ips[count.index]}/24,gw=${cidrhost(format("%s/24", var.ips[count.index]), 1)}"
  ipconfig1 = var.hostnames[count.index] == "nginx" ? "ip=${var.nginx_extern_ip}/24,gw=${var.nginx_extern_gw}" : null

  # Disk – size comes from the per‑VM hardware map
  disk {
    slot    = "virtio0"
    size    = var.hardware[var.hostnames[count.index]].disk
    storage = "local-lvm"
    type    = "disk"
  }

  disk {
    slot    = "ide2"
    type    = "cloudinit"
    storage = "local-lvm"
  }

  # Cloud‑Init
  os_type = "cloud-init"
  ciuser  = var.user
  sshkeys = file(var.ssh_keys["pub"])
  nameserver = var.nameserver

  # Connection (used by provisioners)
  connection {
    host        = var.ips[count.index]
    user        = var.user
    private_key = file(var.ssh_keys["priv"])
    agent       = false
    timeout     = "10m"
  }

  # Provisioners
  provisioner "remote-exec" {
    inline = [
      "echo 'VM ${self.name} is ready for Ansible provisioning'"
    ]
  }
}

# Dynamically create base playbook
resource "local_file" "ansible_base_playbook" {
  filename = "${path.module}/../ansible/base.yml"
  content  = <<EOF
---
- hosts: all
  gather_facts: false
  become: true

  tasks:
    - name: Update apt cache
      apt:
        update_cache: yes
        cache_valid_time: 3600
      failed_when: false
    
    - name: Upgrade installed packages
      apt:
        upgrade: yes

    - name: Ensure admin group exists
      group:
        name: "sudo"
        state: present

    - name: Ensure user exists and is in admin group
      user:
        name: "${var.user}"
        groups: "sudo"
        append: yes
        state: present
        createhome: yes
        shell: /bin/bash

    - name: Ensure passwordless sudo for user (sudoers.d)
      copy:
        dest: "/etc/sudoers.d/90-${var.user}"
        content: "${var.user} ALL=(ALL) NOPASSWD: ALL\n"
        owner: root
        group: root
        mode: "0440"
        validate: "visudo -cf %s"

    - name: Ensure .ssh directory exists
      file:
        path: "/home/${var.user}/.ssh"
        state: directory
        owner: "${var.user}"
        group: "${var.user}"
        mode: "0700"

    - name: Ensure authorized_keys exists
      authorized_key:
        user: "${var.user}"
        state: present
        key: "${trimspace(file(pathexpand(var.ssh_keys["pub"])))}"
EOF
}

# Inventory for ansible
locals {
  wi_hosts = [
    for idx in [3,4,5] :
    "${var.hostnames[idx]} ansible_host=${var.ips[idx]} private_ip=${var.ips[idx]} indexer_node_name=node-${idx - 2}"
  ]

  other_hosts = [
    "${var.hostnames[2]} ansible_host=${var.ips[2]} private_ip=${var.ips[2]}",  # dashboard
    "${var.hostnames[0]} ansible_host=${var.ips[0]} private_ip=${var.ips[0]}",  # manager
    "${var.hostnames[1]} ansible_host=${var.ips[1]} private_ip=${var.ips[1]}"   # worker
  ]
}

# I deliberately don't use templates because I hate having to write all the VMs if they change
resource "local_file" "ansible_inventory" {
  filename = "${path.module}/../ansible/inventory.ini"
  content  = <<EOF
# --- Host definitions (must be outside groups)

# Indexer nodes
${var.hostnames[3]} ansible_host=${var.ips[3]} private_ip=${var.ips[3]} indexer_node_name=node-1
${var.hostnames[4]} ansible_host=${var.ips[4]} private_ip=${var.ips[4]} indexer_node_name=node-2
${var.hostnames[5]} ansible_host=${var.ips[5]} private_ip=${var.ips[5]} indexer_node_name=node-3

# Server/Dashboard nodes (MUST keep these hostnames: manager/worker/dashboard)
dashboard ansible_host=${var.ips[2]} private_ip=${var.ips[2]}
manager   ansible_host=${var.ips[0]} private_ip=${var.ips[0]}
worker    ansible_host=${var.ips[1]} private_ip=${var.ips[1]}

# --- Groups
[wi_cluster]
${var.hostnames[3]}
${var.hostnames[4]}
${var.hostnames[5]}

[dashboard]
dashboard

[manager]
manager

[worker]
worker

[all:vars]
ansible_ssh_user=${var.user}
ansible_ssh_private_key_file=${var.ssh_keys["priv"]}
ansible_ssh_common_args=-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null
ansible_python_interpreter=/usr/bin/python3
EOF
}

# Wazuh cert config for wazuh-certs-tool.sh
resource "local_file" "wazuh_certs_config" {
  filename = "${path.module}/../ansible/wazuh-ansible/playbooks/indexer/certificates/config.yml"
  content  = <<EOF
nodes:
  indexer:
    - name: node-1
      ip: "${var.ips[3]}"
    - name: node-2
      ip: "${var.ips[4]}"
    - name: node-3
      ip: "${var.ips[5]}"

  server:
    - name: node-4
      ip: "${var.ips[0]}"
      node_type: master
    - name: node-5
      ip: "${var.ips[1]}"
      node_type: worker

  dashboard:
    - name: node-6
      ip: "${var.ips[2]}"
EOF
}

# Generate Ansible overrides YAML
resource "local_file" "wazuh_overrides" {
  filename = "${path.module}/../ansible/wazuh-overrides.yml"

  # Critical: DO NOT quote booleans. Also do not quote "indexer_create_custom_user".
  content = <<EOF
# Generated by Terraform. Do not edit manually.

# Dashboard
dashboard_user: "kibanaserver"
dashboard_password: "${var.indexer_kibanaserver_password}"

# Indexer
indexer_security_user: "admin"
indexer_security_password: "${var.indexer_admin_password}"
indexer_admin_password: "${var.indexer_admin_password}"

# Custom user controls (role task guard)
indexer_custom_user: "${var.indexer_custom_user}"
indexer_custom_user_role: "${var.indexer_custom_user_role}"
indexer_create_custom_user: ${var.indexer_create_custom_user}

# Dashboard -> Wazuh API manager credentials (the dashboard should normally use wazuh-wui)
wazuh_api_credentials:
  - id: "default"
    url: "https://${var.ips[0]}"
    port: 55000
    username: "wazuh-wui"
    password: "${var.wazuh_api_wui_password}"
EOF
}

# Run ansible provisioning
resource "null_resource" "run_ansible" {
  depends_on = [
    proxmox_vm_qemu.prox_vm,
    local_file.ansible_inventory,
    local_file.wazuh_overrides,
  ]

  provisioner "local-exec" {
    working_dir = "${path.module}/../ansible"
    command     = <<EOF
      set -e

      ansible-playbook \
        -i inventory.ini \
        -u ${var.user} \
        --key-file ${var.ssh_keys["priv"]} \
        base.yml

      CERT_TOOL_DIR="wazuh-ansible/playbooks/indexer/certificates"
      CERT_DIR="$CERT_TOOL_DIR/wazuh-certificates"

      mkdir -p "$CERT_TOOL_DIR"

      # Download cert tool only if missing
      if [ ! -f "$CERT_TOOL_DIR/wazuh-certs-tool.sh" ]; then
        wget https://packages.wazuh.com/4.14/wazuh-certs-tool.sh -O "$CERT_TOOL_DIR/wazuh-certs-tool.sh"
        chmod +x "$CERT_TOOL_DIR/wazuh-certs-tool.sh"
      fi

      # Generate certs only if missing
      if [ ! -f "$CERT_DIR/root-ca.pem" ]; then
        echo "[INFO] Generating Wazuh certificates..."
        cd "$CERT_TOOL_DIR"
        bash wazuh-certs-tool.sh -A
        cd - >/dev/null
      else
        echo "[INFO] Certificates already present, skipping generation."
      fi

      ansible-playbook \
      -i inventory.ini \
      -e @./wazuh-overrides.yml \
      -u ${var.user} \
      --key-file ${var.ssh_keys["priv"]} \
      wazuh-ansible/playbooks/wazuh-production-ready.yml \
      -b
    EOF
  }
}





# Password files used by wazuh-passwords-tool.sh -f

## Indexer internal users we want to enforce (admin + kibanaserver)
resource "local_file" "wazuh_passwords_indexer_file" {
  filename = "${path.module}/../ansible/passwords-indexer.yml"
  content  = <<EOF
# Managed by Terraform
indexer_username: admin
indexer_password: "${var.indexer_admin_password}"

indexer_username: kibanaserver
indexer_password: "${var.indexer_kibanaserver_password}"
EOF
}

# Apply Indexer passwords on wi1 (var.ips[3])
resource "null_resource" "apply_indexer_passwords_wi1" {
  # IMPORTANT: ensure your ansible provisioning finished first
  depends_on = [
    null_resource.run_ansible,
    local_file.wazuh_passwords_indexer_file,
  ]

  triggers = {
    admin_pass_hash        = sha256(var.indexer_admin_password)
    kibanaserver_pass_hash = sha256(var.indexer_kibanaserver_password)
    # timestamp = "${timestamp()}" # debugging purposes
  }

  provisioner "file" {
    source      = local_file.wazuh_passwords_indexer_file.filename
    destination = "/tmp/passwords-indexer.yml"

    connection {
      host        = var.ips[3] # wi1
      user        = var.user
      private_key = file(var.ssh_keys["priv"])
      agent       = false
    }
  }

  provisioner "remote-exec" {
    inline = [
    "set -e",
    "sudo /usr/share/wazuh-indexer/plugins/opensearch-security/tools/wazuh-passwords-tool.sh -f /tmp/passwords-indexer.yml",
    "sudo rm -f /tmp/passwords-indexer.yml"
    ]

    connection {
      host        = var.ips[3] # wi1
      user        = var.user
      private_key = file(var.ssh_keys["priv"])
      agent       = false
    }
  }
}

# Apply Indexer passwords on wi2 (var.ips[4])
resource "null_resource" "apply_indexer_passwords_wi2" {
  # IMPORTANT: ensure your ansible provisioning finished first
  depends_on = [
    null_resource.run_ansible,
    local_file.wazuh_passwords_indexer_file,
    null_resource.apply_indexer_passwords_wi1,
  ]

  triggers = {
    admin_pass_hash        = sha256(var.indexer_admin_password)
    kibanaserver_pass_hash = sha256(var.indexer_kibanaserver_password)
    # timestamp = "${timestamp()}" # debugging purposes
  }

  provisioner "file" {
    source      = local_file.wazuh_passwords_indexer_file.filename
    destination = "/tmp/passwords-indexer.yml"

    connection {
      host        = var.ips[4] # wi2
      user        = var.user
      private_key = file(var.ssh_keys["priv"])
      agent       = false
    }
  }

  provisioner "remote-exec" {
    inline = [
    "set -e",
    "sudo /usr/share/wazuh-indexer/plugins/opensearch-security/tools/wazuh-passwords-tool.sh -f /tmp/passwords-indexer.yml",
    "sudo rm -f /tmp/passwords-indexer.yml"
    ]

    connection {
      host        = var.ips[4] # wi2
      user        = var.user
      private_key = file(var.ssh_keys["priv"])
      agent       = false
    }
  }
}

# Apply Indexer passwords on wi3 (var.ips[5])
resource "null_resource" "apply_indexer_passwords_wi3" {
  # IMPORTANT: ensure your ansible provisioning finished first
  depends_on = [
    null_resource.run_ansible,
    local_file.wazuh_passwords_indexer_file,
    null_resource.apply_indexer_passwords_wi1,
  ]

  triggers = {
    admin_pass_hash        = sha256(var.indexer_admin_password)
    kibanaserver_pass_hash = sha256(var.indexer_kibanaserver_password)
    # timestamp = "${timestamp()}" # debugging purposes
  }

  provisioner "file" {
    source      = local_file.wazuh_passwords_indexer_file.filename
    destination = "/tmp/passwords-indexer.yml"

    connection {
      host        = var.ips[5] # wi3
      user        = var.user
      private_key = file(var.ssh_keys["priv"])
      agent       = false
    }
  }

  provisioner "remote-exec" {
    inline = [
    "set -e",
    "sudo /usr/share/wazuh-indexer/plugins/opensearch-security/tools/wazuh-passwords-tool.sh -f /tmp/passwords-indexer.yml",
    "sudo rm -f /tmp/passwords-indexer.yml"
    ]

    connection {
      host        = var.ips[5] # wi3
      user        = var.user
      private_key = file(var.ssh_keys["priv"])
      agent       = false
    }
  }
}

# Update Filebeat keystore on manager + worker (admin)
resource "null_resource" "update_filebeat_keystore_manager_worker" {
  depends_on = [
    null_resource.apply_indexer_passwords_wi1,
    null_resource.apply_indexer_passwords_wi2,
    null_resource.apply_indexer_passwords_wi3,
  ]

  triggers = {
    admin_pass_hash = sha256(var.indexer_admin_password)
    # timestamp = "${timestamp()}" # debugging purposes
  }

  # manager
  provisioner "remote-exec" {
    inline = [
      "set -e",
      "echo 'admin' | sudo filebeat keystore add username --stdin --force",
      "printf '%s' '${var.indexer_admin_password}' | sudo filebeat keystore add password --stdin --force",
      "sleep 30 && sudo systemctl restart filebeat",
    ]

    connection {
      host        = var.ips[0] # manager
      user        = var.user
      private_key = file(var.ssh_keys["priv"])
      agent       = false
      timeout     = "10m"
    }
  }

  # worker
  provisioner "remote-exec" {
    inline = [
      "set -e",
      "echo 'admin' | sudo filebeat keystore add username --stdin --force",
      "echo '${var.indexer_admin_password}' | sudo filebeat keystore add password --stdin --force",
      "sleep 30 && sudo systemctl restart filebeat",
    ]

    connection {
      host        = var.ips[1] # worker
      user        = var.user
      private_key = file(var.ssh_keys["priv"])
      agent       = false
      timeout     = "10m"
    }
  }
}

# Update Dashboard keystore with kibanaserver password
resource "null_resource" "update_dashboard_opensearch_keystore" {
  depends_on = [
    null_resource.apply_indexer_passwords_wi1,
    null_resource.apply_indexer_passwords_wi2,
    null_resource.apply_indexer_passwords_wi3,
  ]

  triggers = {
    kibanaserver_pass_hash = sha256(var.indexer_kibanaserver_password)
    # timestamp = "${timestamp()}" # debugging purposes
  }

  provisioner "remote-exec" {
    inline = [
      "set -e",
      "sudo systemctl stop wazuh-dashboard || true",
      "echo 'kibanaserver' | sudo /usr/share/wazuh-dashboard/bin/opensearch-dashboards-keystore --allow-root add -f --stdin opensearch.username",
      "printf '%s' '${var.indexer_kibanaserver_password}' | sudo /usr/share/wazuh-dashboard/bin/opensearch-dashboards-keystore --allow-root add -f --stdin opensearch.password",
      "sleep 120 && sudo systemctl restart wazuh-dashboard",
    ]

    connection {
      host        = var.ips[2] # dashboard
      user        = var.user
      private_key = file(var.ssh_keys["priv"])
      agent       = false
      timeout     = "10m"
    }
  }
}

# Rotate Wazuh API passwords on manager
resource "null_resource" "apply_wazuh_api_passwords" {
  depends_on = [
    null_resource.run_ansible,
    null_resource.update_dashboard_opensearch_keystore,
  ]

  triggers = {
    wazuh_pass_hash    = sha256(var.wazuh_api_password)
    wazuh_wui_pass_hash = sha256(var.wazuh_api_wui_password)
    # timestamp = "${timestamp()}" # debugging purposes
  }

  provisioner "remote-exec" {
    inline = [
      "set -e",

      "cd /tmp",
      "sudo curl -sO https://packages.wazuh.com/4.14/wazuh-passwords-tool.sh",
      "sudo chmod +x /tmp/wazuh-passwords-tool.sh",

      # Changing creds using default admin creds "wazuh:wazuh"
      "sudo /tmp/wazuh-passwords-tool.sh -A -u wazuh-wui -p '${var.wazuh_api_wui_password}' -au wazuh -ap wazuh || true",
      "sudo /tmp/wazuh-passwords-tool.sh -A -u wazuh -p '${var.wazuh_api_password}' -au wazuh -ap wazuh || true",

      "sudo rm -f /tmp/wazuh-passwords-tool.sh",
      "sleep 60 && sudo service wazuh-manager restart",
    ]

    connection {
      host        = var.ips[0] # manager
      user        = var.user
      private_key = file(var.ssh_keys["priv"])
      agent       = false
      timeout     = "10m"
    }
  }
}
