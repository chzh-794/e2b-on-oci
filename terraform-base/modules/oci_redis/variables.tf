variable "compartment_id" {
  description = "Compartment OCID"
  type        = string
}

variable "display_name" {
  description = "Display name for the Redis cluster"
  type        = string
}

variable "node_count" {
  description = "Number of nodes"
  type        = number
}

variable "node_memory_in_gbs" {
  description = "Memory per node in GB"
  type        = number
}

variable "software_version" {
  description = "Redis engine version"
  type        = string
}

variable "subnet_id" {
  description = "Subnet OCID"
  type        = string
}

variable "cluster_mode" {
  description = "Cluster mode (NONSHARDED or SHARDED)"
  type        = string
  default     = "NONSHARDED"
}

variable "nsg_ids" {
  description = "List of NSG OCIDs"
  type        = list(string)
  default     = []
}

variable "shard_count" {
  description = "Number of shards when cluster mode is SHARDED"
  type        = number
  default     = null
}

variable "defined_tags" {
  description = "Defined tags"
  type        = map(string)
  default     = {}
}

variable "freeform_tags" {
  description = "Freeform tags"
  type        = map(string)
  default     = {}
}

