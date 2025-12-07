# ===================================================================================================
# TERRAFORM CONFIGURATION
# ===================================================================================================

terraform {
  required_version = ">= 1.0"
  required_providers {
    oci = {
      source  = "oracle/oci"
      version = "~> 5.0"
    }
  }
}

# Default provider uses the caller's region; home alias can override when IAM must target a home region
provider "oci" {
  region = var.region
}

provider "oci" {
  alias  = "home"
  region = coalesce(var.home_region, var.region)
}

# Get compartment details for readable policy statements
data "oci_identity_compartment" "target_compartment" {
  id = var.compartment_ocid
}

# ===================================================================================================
# IAM: DYNAMIC GROUP AND POLICIES
# ===================================================================================================

resource "oci_identity_dynamic_group" "service_dynamic_group" {
  provider       = oci.home
  compartment_id = var.tenancy_ocid
  name           = "${var.prefix}-service-dynamic-group"
  description    = "E2B service instances within the compartment (bastion, clusters, managed services)"
  matching_rule  = "instance.compartment.id = '${var.compartment_ocid}'"
}

resource "oci_identity_policy" "bastion_policy" {
  provider       = oci.home
  compartment_id = var.tenancy_ocid
  name           = "${var.prefix}-bastion-policy"
  description    = "Policy for E2B bastion to manage compute resources via Packer"
  
  statements = [
    "Allow dynamic-group ${oci_identity_dynamic_group.service_dynamic_group.name} to manage instance-family in compartment ${data.oci_identity_compartment.target_compartment.name}",
    "Allow dynamic-group ${oci_identity_dynamic_group.service_dynamic_group.name} to manage compute-image-capability-schema in compartment ${data.oci_identity_compartment.target_compartment.name}",
    "Allow dynamic-group ${oci_identity_dynamic_group.service_dynamic_group.name} to manage volume-family in compartment ${data.oci_identity_compartment.target_compartment.name}",
    "Allow dynamic-group ${oci_identity_dynamic_group.service_dynamic_group.name} to manage virtual-network-family in compartment ${data.oci_identity_compartment.target_compartment.name}",
  ]
}

resource "oci_identity_policy" "service_policy" {
  provider       = oci.home
  compartment_id = var.tenancy_ocid
  name           = "${var.prefix}-service-policy"
  description    = "Policy for E2B services to access managed resources"

  statements = [
    "Allow dynamic-group ${oci_identity_dynamic_group.service_dynamic_group.name} to manage postgres-db-systems in compartment ${data.oci_identity_compartment.target_compartment.name}",
    "Allow dynamic-group ${oci_identity_dynamic_group.service_dynamic_group.name} to manage postgres-backups in compartment ${data.oci_identity_compartment.target_compartment.name}",
    "Allow dynamic-group ${oci_identity_dynamic_group.service_dynamic_group.name} to read postgres-work-requests in compartment ${data.oci_identity_compartment.target_compartment.name}",
    "Allow dynamic-group ${oci_identity_dynamic_group.service_dynamic_group.name} to manage postgres-configuration in compartment ${data.oci_identity_compartment.target_compartment.name}",
    "Allow dynamic-group ${oci_identity_dynamic_group.service_dynamic_group.name} to {REDIS_CLUSTER_USE} in compartment ${data.oci_identity_compartment.target_compartment.name}",
    "Allow dynamic-group ${oci_identity_dynamic_group.service_dynamic_group.name} to manage buckets in compartment ${data.oci_identity_compartment.target_compartment.name}",
    "Allow dynamic-group ${oci_identity_dynamic_group.service_dynamic_group.name} to manage repos in compartment ${data.oci_identity_compartment.target_compartment.name}"
  ]
}
