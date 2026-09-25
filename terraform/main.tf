resource "clouding_firewall" "valheim" {
  name        = "valheim-server-firewall"
  description = "Restricted SSH and Valheim game traffic"
}

resource "clouding_firewall_rule" "ssh" {
  firewall_id    = clouding_firewall.valheim.id
  source_ip      = var.admin_cidr
  protocol       = "tcp"
  port_range_min = 22
  port_range_max = 22
  description    = "SSH from the administrator CIDR"
}

resource "clouding_firewall_rule" "valheim" {
  firewall_id    = clouding_firewall.valheim.id
  source_ip      = "0.0.0.0/0"
  protocol       = "udp"
  port_range_min = 2456
  port_range_max = 2457
  description    = "Valheim game traffic"
}

resource "clouding_server" "valheim" {
  name        = var.server_name
  hostname    = var.hostname
  flavor_id   = var.flavor_id
  firewall_id = clouding_firewall.valheim.id

  access_configuration = {
    ssh_key_id = var.ssh_key_id
  }

  volume = {
    source = "image"
    id     = var.image_id
    ssd_gb = var.ssd_gb
  }

  backup_preference = var.clouding_backup_enabled ? {
    frequency = var.clouding_backup_frequency
    slots     = var.clouding_backup_slots
  } : null

  user_data = replace(file("${path.module}/cloud-init.yaml"), "__ADMIN_CIDR__", var.admin_cidr)
}
