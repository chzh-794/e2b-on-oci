output "server_instance_configuration_id" {
  description = "OCID of the server instance configuration."
  value       = oci_core_instance_configuration.server.id
}

output "server_instance_pool_id" {
  description = "OCID of the server instance pool."
  value       = oci_core_instance_pool.server.id
}

output "api_instance_pool_id" {
  description = "OCID of the API instance pool."
  value       = oci_core_instance_pool.api.id
}

output "client_instance_pool_id" {
  description = "OCID of the client instance pool."
  value       = oci_core_instance_pool.client.id
}


