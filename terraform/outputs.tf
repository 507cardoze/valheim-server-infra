output "server_id" {
  description = "Clouding ID of the Valheim server."
  value       = clouding_server.valheim.id
}

output "firewall_id" {
  description = "Clouding ID of the Valheim firewall."
  value       = clouding_firewall.valheim.id
}

