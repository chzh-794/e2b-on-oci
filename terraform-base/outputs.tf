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

output "ssh_command" {
  description = "SSH command to connect to bastion"
  value       = "ssh ubuntu@${oci_core_instance.bastion.public_ip}"
}

output "ssh_private_key" {
  description = "Auto-generated SSH private key (save this to a file!)"
  value       = try(tls_private_key.ssh[0].private_key_openssh, "N/A - Using provided key")
  sensitive   = true
}

output "ssh_key_generated" {
  description = "Whether SSH key was auto-generated (true) or user-provided (false)"
  value       = var.ssh_public_key == null && var.ssh_public_key_path == null
}

output "how_to_get_ssh_key" {
  description = "Instructions to retrieve auto-generated SSH key"
  value       = var.ssh_public_key == null && var.ssh_public_key_path == null ? "Click 'Show' on ssh_private_key output in OCI Console, or run: terraform output -raw ssh_private_key" : "Using your provided SSH key"
}

# ===================================================================================================
# DATABASE CREDENTIALS
# ===================================================================================================

output "db_admin_password" {
  description = "Auto-generated database admin password (save this securely!)"
  value       = local.db_admin_password
  sensitive   = true
}

output "db_name" {
  description = "Database name"
  value       = var.db_name
}

output "db_connection_info" {
  description = "How to retrieve database password after deployment"
  value       = "Run: terraform output -raw db_admin_password"
}

# ===================================================================================================
# IMAGE INFORMATION
# ===================================================================================================

output "ubuntu_image_id" {
  description = "OCID of the Ubuntu 22.04 image used"
  value       = data.oci_core_images.ubuntu_2204.images[0].id
}

output "ubuntu_image_name" {
  description = "Name of the Ubuntu 22.04 image"
  value       = data.oci_core_images.ubuntu_2204.images[0].display_name
}

