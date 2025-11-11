variable "compartment_id" {
  description = "OCID of the compartment where the bucket will be created"
  type        = string
}

variable "bucket_name" {
  description = "Name of the object storage bucket"
  type        = string
}

variable "access_type" {
  description = "Bucket access type"
  type        = string
  default     = "NoPublicAccess"
}

variable "auto_tiering" {
  description = "Auto tiering setting"
  type        = string
  default     = "InfrequentAccess"
}

variable "defined_tags" {
  description = "Defined tags to apply to the bucket"
  type        = map(string)
  default     = {}
}

variable "freeform_tags" {
  description = "Freeform tags to apply to the bucket"
  type        = map(string)
  default     = {}
}

variable "create_lifecycle_policy" {
  description = "Whether to create an object lifecycle policy"
  type        = bool
  default     = false
}

variable "lifecycle_time_amount" {
  description = "Lifecycle rule retention amount"
  type        = number
  default     = 30
}

variable "lifecycle_time_unit" {
  description = "Lifecycle rule retention unit"
  type        = string
  default     = "DAYS"
}

variable "create_replication_policy" {
  description = "Whether to create a replication policy"
  type        = bool
  default     = false
}

variable "replication_destination_bucket_name" {
  description = "Destination bucket name for replication"
  type        = string
  default     = null
}

variable "replication_destination_region" {
  description = "Destination region for replication"
  type        = string
  default     = null
}


