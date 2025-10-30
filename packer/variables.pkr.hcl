# ===================================================================================================
# Packer Variables for E2B on OCI
# ===================================================================================================
# These values come from Phase 1 Terraform outputs

variable "compartment_ocid" {
  type        = string
  description = "OCID of compartment (from Phase 1 Terraform output)"
}

variable "availability_domain" {
  type        = string
  description = "Availability domain name (from Phase 1 Terraform output: bastion_availability_domain)"
}

variable "subnet_ocid" {
  type        = string
  description = "Public subnet OCID (from Phase 1 Terraform output: public_subnet_id)"
}

variable "ubuntu_image_ocid" {
  type        = string
  description = "Ubuntu 22.04 image OCID (from Phase 1 Terraform output: ubuntu_image_id)"
}

# ===================================================================================================
# Build Instance Configuration
# ===================================================================================================

variable "build_shape" {
  type        = string
  description = "Compute shape for build instance (VM is cheaper than BM)"
  default     = "VM.Standard3.Flex"
}

variable "build_ocpus" {
  type        = number
  description = "OCPUs for build instance"
  default     = 2
}

variable "build_memory_gb" {
  type        = number
  description = "Memory in GB for build instance"
  default     = 8
}

# ===================================================================================================
# Software Versions (matches AWS configuration)
# ===================================================================================================

variable "consul_version" {
  type        = string
  description = "Consul version to install"
  default     = "1.16.2"
}

variable "nomad_version" {
  type        = string
  description = "Nomad version to install"
  default     = "1.6.2"
}

