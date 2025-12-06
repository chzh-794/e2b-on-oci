# ===================================================================================================
# CORE OCI CONFIGURATION
# ===================================================================================================

variable "tenancy_ocid" {
  type        = string
  description = "OCID of the tenancy where IAM resources are managed"
}

variable "region" {
  type        = string
  description = "Region to target when creating policies by default"
}

variable "home_region" {
  type        = string
  description = "Optional override for IAM home region; defaults to the current region when unset"
  default     = null
}

variable "compartment_ocid" {
  type        = string
  description = "OCID of the compartment where workloads run (used in dynamic group rule)"
}

variable "prefix" {
  type        = string
  description = "Prefix for resource names (e.g., e2b)"
  default     = "e2b"
}
