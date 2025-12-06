# ===================================================================================================
# IAM OUTPUTS
# ===================================================================================================

output "service_dynamic_group_id" {
  description = "OCID of the dynamic group granting OCI services permissions to instances in the compartment"
  value       = oci_identity_dynamic_group.service_dynamic_group.id
}

output "bastion_policy_id" {
  description = "OCID of the bastion policy"
  value       = oci_identity_policy.bastion_policy.id
}

output "service_policy_id" {
  description = "OCID of the service policy"
  value       = oci_identity_policy.service_policy.id
}
