output "db_system_id" {
  description = "OCID of the PostgreSQL DB system"
  value       = oci_psql_db_system.this.id
}

output "configuration_id" {
  description = "OCID of the configuration in use"
  value       = local.create_configuration ? oci_psql_configuration.this[0].id : var.config_id
}

