# ===================================================================================================
# REGION AND AVAILABILITY DOMAINS (auto-detected like AWS)
# ===================================================================================================

// Region output not needed; OCI Resource Manager sets region implicitly

output "available_ads" {
  description = "Available Availability Domains in region (auto-spread like AWS AZs)"
  value       = local.all_availability_domains
}

output "bastion_availability_domain" {
  description = "Availability Domain where bastion is deployed"
  value       = local.availability_domain
}

# ===================================================================================================
# NETWORKING OUTPUTS
# ===================================================================================================

output "vcn_id" {
  description = "OCID of the VCN"
  value       = oci_core_vcn.e2b_vcn.id
}

output "vcn_cidr_block" {
  description = "CIDR block assigned to the VCN"
  value       = var.vcn_cidr_block
}

output "public_subnet_id" {
  description = "OCID of the public subnet"
  value       = oci_core_subnet.e2b_public_subnet.id
}

output "private_subnet_id" {
  description = "OCID of the private subnet"
  value       = oci_core_subnet.e2b_private_subnet.id
}

output "public_lb_subnet_id" {
  description = "OCID of the public load balancer subnet (if created)"
  value       = var.create_load_balancer ? oci_core_subnet.e2b_public_lb_subnet[0].id : null
}

output "nat_gateway_id" {
  description = "OCID of the NAT Gateway"
  value       = oci_core_nat_gateway.e2b_nat_gw.id
}

output "service_gateway_id" {
  description = "OCID of the Service Gateway"
  value       = oci_core_service_gateway.e2b_service_gw.id
}

# ===================================================================================================
# BASTION OUTPUTS
# ===================================================================================================

output "bastion_public_ip" {
  description = "Public IP address of the bastion instance"
  value       = oci_core_instance.bastion.public_ip
}

output "bastion_instance_id" {
  description = "OCID of the bastion instance"
  value       = oci_core_instance.bastion.id
}

# ===================================================================================================
# OBJECT STORAGE, POSTGRESQL, REDIS
# ===================================================================================================

output "object_storage_buckets" {
  description = "Object storage buckets provisioned for E2B"
  value = var.enable_object_storage ? {
    for key, mod in module.object_storage_buckets :
    key => {
      id        = mod.bucket_id
      name      = mod.bucket_name
      namespace = mod.namespace
    }
  } : {}
}

output "postgresql_db_system_id" {
  description = "OCID of the PostgreSQL DB system"
  value       = var.enable_postgresql ? module.postgresql[0].db_system_id : null
}

output "redis_primary_fqdn" {
  description = "Primary FQDN for the Redis cluster"
  value       = var.enable_redis ? module.redis_cluster[0].primary_fqdn : null
}

# ===================================================================================================
# DATABASE CREDENTIALS
# ===================================================================================================

output "db_admin_password" {
  description = "Auto-generated database admin password (save this securely!)"
  value       = var.postgresql_admin_password
  # Visible in Resource Manager outputs for easy retrieval during POC
  # In production, switch to OCI Vault or OCI Secrets for secure storage
  sensitive   = false
}

# ===================================================================================================
# IMAGE INFORMATION
# ===================================================================================================

output "ubuntu_image_id" {
  description = "OCID of the x86_64 Ubuntu 22.04 image"
  value       = local.ubuntu_image_id
}

output "ubuntu_image_name" {
  description = "Name of the x86_64 Ubuntu 22.04 image (for debugging)"
  value       = local.ubuntu_image_name
}
