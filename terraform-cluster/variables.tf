variable "region" {
  type        = string
  description = "OCI region where the cluster will be deployed."
}

variable "compartment_ocid" {
  type        = string
  description = "Compartment OCID that holds the cluster resources."
}

variable "environment" {
  type        = string
  description = "Deployment environment label (e.g., dev, prod)."
  default     = "dev"
}

variable "prefix" {
  type        = string
  description = "Resource name prefix to align with AWS naming."
  default     = "e2b"
}

variable "vcn_id" {
  type        = string
  description = "VCN OCID created by terraform-base."
}

variable "vcn_cidr_block" {
  type        = string
  description = "CIDR block for the VCN; used for NSG ingress rules."
}

variable "private_subnet_id" {
  type        = string
  description = "Private subnet OCID for service instances."
}

variable "custom_image_ocid" {
  type        = string
  description = "OCID of the custom image built via Packer (stage 1)."
}

variable "ssh_public_key" {
  type        = string
  description = "SSH public key added to cluster instances."
}

variable "cluster_setup_bucket_name" {
  type        = string
  description = "Object Storage bucket containing bootstrap scripts (mirrors AWS cluster-setup bucket)."
  default     = "cluster-setup"
}

variable "consul_gossip_encryption_key" {
  type        = string
  description = "Base64 gossip encryption key for Consul."
  # 32-byte key base64-encoded; replace with Vault-managed secret for production.
  default     = "u1N1pLZm4iM5XOoCFu3Hy7Db2Z7hP6rXH0y0Y9MZ4XI="
}

variable "server_shape" {
  type        = string
  description = "Compute shape for Nomad/Consul server instances."
  default     = "VM.Standard3.Flex"
}

variable "server_ocpus" {
  type        = number
  description = "OCPU count for each server instance."
  default     = 4
}

variable "server_memory_in_gbs" {
  type        = number
  description = "Memory allocation (GB) for each server instance."
  default     = 16
}

variable "server_desired_capacity" {
  type        = number
  description = "Number of servers in the cluster."
  default     = 3
}

variable "api_shape" {
  type        = string
  description = "Compute shape for API pool instances."
  default     = "VM.Standard3.Flex"
}

variable "api_ocpus" {
  type        = number
  description = "OCPU count for each API pool instance."
  default     = 4
}

variable "api_memory_in_gbs" {
  type        = number
  description = "Memory allocation (GB) for each API pool instance."
  default     = 16
}

variable "api_desired_capacity" {
  type        = number
  description = "Number of instances in the API pool."
  default     = 1
}

variable "client_shape" {
  type        = string
  description = "Compute shape for client pool instances."
  default     = "VM.Standard3.Flex"
}

variable "client_ocpus" {
  type        = number
  description = "OCPU count for each client pool instance."
  default     = 8
}

variable "client_memory_in_gbs" {
  type        = number
  description = "Memory allocation (GB) for each client pool instance."
  default     = 64
}

variable "client_desired_capacity" {
  type        = number
  description = "Number of instances in the client pool."
  default     = 1
}

variable "defined_tags" {
  type        = map(string)
  description = "OCI defined tags applied to cluster resources."
  default     = {}
}

variable "freeform_tags" {
  type        = map(string)
  description = "OCI freeform tags applied to cluster resources."
  default     = {}
}

variable "auto_bootstrap" {
  type        = bool
  description = "Whether server user-data should automatically run the Consul/Nomad bootstrap scripts."
  default     = true
}

