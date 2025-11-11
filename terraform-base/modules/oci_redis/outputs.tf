output "redis_cluster_id" {
  description = "OCID of the Redis cluster"
  value       = oci_redis_redis_cluster.this.id
}

output "primary_fqdn" {
  description = "Primary endpoint FQDN"
  value       = oci_redis_redis_cluster.this.primary_fqdn
}

output "replicas_fqdn" {
  description = "Replica endpoints"
  value       = oci_redis_redis_cluster.this.replicas_fqdn
}

