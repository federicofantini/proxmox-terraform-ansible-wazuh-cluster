provider "proxmox" {
  pm_api_url      = var.proxmox_host["pm_api_url"]
  pm_user         = var.proxmox_host["pm_user"]
  pm_password     = var.proxmox_host["pm_password"]
  pm_tls_insecure = var.proxmox_host["pm_tls_insecure"]

  pm_log_enable = true
  pm_log_file   = "terraform-plugin-proxmox.log"
  pm_debug      = true
  pm_log_levels = {
    _default    = "info"
    _capturelog = ""
  }
}
