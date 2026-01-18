# Proxmox connection
variable "proxmox_host" {
  description = "Proxmox API connection settings"
  type        = map(string)
  sensitive   = true
  default = {
    pm_api_url      = "https://10.10.10.10:8006/api2/json"
    pm_user         = "root@pam"
    pm_password     = "changeme"
    pm_tls_insecure = false
    target_node     = "pve"
  }
}

# Starting VMID for the first VM
variable "vmid" {
  description = "Starting VMID (the next VMs will use vmid+index)"
  type        = number
  default     = 1000
}

# Topology 
variable "hostnames" {
  description = "Hostnames of the VMs to create. Order must match var.ips"
  type        = list(string)
  default     = ["wazuh-single", "nginx"]
}

variable "ips" {
  description = "Static IPs for the VMs (VLAN/internal). Order must match var.hostnames"
  type        = list(string)
}

variable "nameserver" {
  description = "Nameserver used by every VM"
  type        = string
  default     = "1.1.1.1"
}

variable "vlan_tag" {
  description = "VLAN ID to apply to the internal NIC. Set to null for untagged"
  type        = number
  default     = null
}

# Per‑VM hardware definition (CPU, RAM, Disk)
variable "hardware" {
  description = "Map of hostname => hardware spec"
  type = map(object({
    cores   = number
    sockets = number
    memory  = number
    disk    = string
  }))
}

# SSH / Cloud-init
variable "ssh_keys" {
  type = map(string)
}

variable "user" {
  description = "Non-root cloud-init user used for provisioning"
  type        = string
  default     = "rain"
}

# Nginx (2nd NIC on LAN/external side)
variable "nginx_extern_ip" {
  description = "External/LAN IP for nginx (second NIC). Used only if hostname 'nginx' exists."
  type        = string
  default     = ""
}

variable "nginx_extern_gw" {
  description = "External/LAN gateway for nginx (second NIC). Used only if hostname 'nginx' exists."
  type        = string
  default     = ""
}

# Wazuh passwords / users 
variable "indexer_admin_password" {
  type      = string
  sensitive = true
}

variable "indexer_kibanaserver_password" {
  type      = string
  sensitive = true
}

variable "indexer_custom_user" {
  type    = string
  default = ""
}

variable "indexer_custom_user_role" {
  type    = string
  default = ""
}

variable "indexer_create_custom_user" {
  type    = bool
  default = false
}

variable "wazuh_api_password" {
  type      = string
  sensitive = true
}

variable "wazuh_api_wui_password" {
  type      = string
  sensitive = true
}
