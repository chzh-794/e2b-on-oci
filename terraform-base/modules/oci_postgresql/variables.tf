variable "compartment_id" {
  description = "Compartment OCID for the PostgreSQL resources"
  type        = string
}

variable "db_username" {
  description = "Administrative database username"
  type        = string
}

variable "db_password" {
  description = "Administrative database password"
  type        = string
  sensitive   = true
}

variable "db_version" {
  description = "PostgreSQL engine version"
  type        = string
}

variable "subnet_id" {
  description = "Subnet OCID for the DB system"
  type        = string
}

variable "nsg_ids" {
  description = "Optional list of NSG OCIDs"
  type        = list(string)
  default     = []
}

variable "shape" {
  description = "Compute shape used for PostgreSQL configuration"
  type        = string
  default     = "VM.Standard.E5.Flex"
}

variable "db_system_shape" {
  description = "Shape for the PostgreSQL DB system"
  type        = string
  default     = "PostgreSQL.VM.Standard.E5.Flex"
}

variable "instance_count" {
  description = "Number of DB instances"
  type        = number
  default     = 1
}

variable "instance_memory_gbs" {
  description = "Memory per instance in GB"
  type        = number
  default     = 64
}

variable "instance_ocpu_count" {
  description = "OCPUs per instance"
  type        = number
  default     = 4
}

variable "iops" {
  description = "Provisioned IOPS"
  type        = number
  default     = 75000
}

variable "is_regionally_durable" {
  description = "Whether to use regional durable storage"
  type        = bool
  default     = true
}

variable "storage_availability_domain" {
  description = "Availability domain for AD-local storage (required when is_regionally_durable is false)"
  type        = string
  default     = null
}

variable "enable_reader_endpoint" {
  description = "Whether to enable reader endpoint"
  type        = bool
  default     = true
}

variable "display_name" {
  description = "Display name for the DB system"
  type        = string
  default     = null
}

variable "config_id" {
  description = "Existing PostgreSQL configuration OCID"
  type        = string
  default     = null
}

variable "effective_io_concurrency" {
  description = "Override for effective_io_concurrency"
  type        = string
  default     = "1"
}

variable "freeform_tags" {
  description = "Freeform tags"
  type        = map(string)
  default     = {}
}

variable "defined_tags" {
  description = "Defined tags"
  type        = map(string)
  default     = {}
}


