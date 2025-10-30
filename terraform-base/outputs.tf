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

output "public_subnet_id" {
  description = "OCID of the public subnet"
  value       = oci_core_subnet.e2b_public_subnet.id
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
# DATABASE CREDENTIALS
# ===================================================================================================

output "db_admin_password" {
  description = "Auto-generated database admin password (save this securely!)"
  value       = local.db_admin_password
  # Visible in Resource Manager outputs for easy retrieval
  # In production, use OCI Vault to store secrets securely
  sensitive   = false
}

output "db_name" {
  description = "Database name"
  value       = var.db_name
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

