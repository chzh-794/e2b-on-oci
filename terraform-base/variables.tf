# ===================================================================================================
# Core OCI Configuration
# ===================================================================================================

variable "tenancy_ocid" {
}

variable "region" {
  type        = string
  description = "The region in which to create all resources"
}

variable "compartment_ocid" {
  type        = string
  description = "OCID of the compartment where resources will be created"
}

# Note: Availability Domains are auto-selected (like AWS auto-spreads across AZs)
# No user input needed - resources automatically distributed for high availability

# ===================================================================================================
# Environment Configuration
# ===================================================================================================

variable "environment" {
  type        = string
  description = "Environment: dev or prod"
  default     = "dev"
  validation {
    condition     = contains(["dev", "prod"], var.environment)
    error_message = "Environment must be 'dev' or 'prod'."
  }
}

variable "prefix" {
  type        = string
  description = "Prefix for resource names (e.g., e2b)"
  default     = "e2b"
}

# ===================================================================================================
# VCN Configuration
# ===================================================================================================

variable "vcn_cidr_block" {
  type        = string
  description = "CIDR block for the VCN"
  default     = "10.0.0.0/16"
}

variable "public_subnet_cidr" {
  type        = string
  description = "CIDR block for public subnet"
  default     = "10.0.1.0/24"
}

variable "private_subnet_cidr" {
  type        = string
  description = "CIDR block for private subnet"
  default     = "10.0.2.0/24"
}

variable "public_lb_subnet_cidr" {
  type        = string
  description = "CIDR block for public load balancer subnet"
  default     = "10.0.3.0/24"
}

variable "create_load_balancer" {
  type        = bool
  description = "Whether to create load balancer subnet (set to true when adding load balancer)"
  default     = false
}

# ===================================================================================================
# Bastion Configuration
# ===================================================================================================

variable "bastion_shape" {
  type        = string
  description = "Compute shape for bastion instance"
  default     = "VM.Standard3.Flex"
}

variable "bastion_ocpus" {
  type        = number
  description = "Number of OCPUs for bastion (AWS c7i.xlarge = 4 OCPUs)"
  default     = 4
}

variable "bastion_memory_in_gbs" {
  type        = number
  description = "Memory in GBs for bastion (AWS c7i.xlarge = 8GB)"
  default     = 8
}

variable "ssh_public_key" {
  type        = string
  description = <<-EOT
    SSH public key for bastion access (paste entire content of ~/.ssh/id_rsa.pub).
    Example: "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQ... user@host"
  EOT
  default     = null
}

variable "ssh_public_key_path" {
  type        = string
  description = "Path to SSH public key file on local filesystem (alternative to pasting)"
  default     = null
}

variable "allowed_ssh_cidr" {
  type        = string
  description = "CIDR block allowed for SSH access to bastion"
  default     = "0.0.0.0/0"
}

# ===================================================================================================
# Database Configuration
# ===================================================================================================
# Note: Database admin password is auto-generated for security
# Retrieve from outputs after deployment

# Note: Domain configuration will be added in later phases when Load Balancer is deployed

variable "db_name" {
  type        = string
  description = "Name for the database"
  default     = "e2bdb"
}

# ===================================================================================================
# Managed Services Toggles & Settings
# ===================================================================================================

variable "enable_object_storage" {
  type        = bool
  description = "Whether to create OCI Object Storage buckets"
  default     = true
}

variable "enable_postgresql" {
  type        = bool
  description = "Whether to create the managed PostgreSQL database"
  default     = true
}

variable "enable_redis" {
  type        = bool
  description = "Whether to create the OCI Redis cluster"
  default     = true
}

variable "postgresql_db_version" {
  type        = string
  description = "PostgreSQL version for the managed database"
  default     = "15"
}

variable "postgresql_instance_count" {
  type        = number
  description = "Number of PostgreSQL instances"
  default     = 1
}

variable "postgresql_instance_memory_gbs" {
  type        = number
  description = "Memory per PostgreSQL instance in GB"
  default     = 64
}

variable "postgresql_instance_ocpus" {
  type        = number
  description = "OCPUs per PostgreSQL instance"
  default     = 4
}

variable "postgresql_iops" {
  type        = number
  description = "Provisioned IOPS for PostgreSQL storage"
  default     = 75000
}

variable "postgresql_admin_password" {
  type        = string
  description = "Hard-coded admin password for the PostgreSQL database (POC only; replace with OCI Vault in production)"
  default     = "E2bP0cPostgres!2025"
}

variable "redis_node_count" {
  type        = number
  description = "Number of nodes for the Redis cluster"
  default     = 3
}

variable "redis_node_memory_gbs" {
  type        = number
  description = "Memory per Redis node in GB"
  default     = 16
}

variable "redis_software_version" {
  type        = string
  description = "Redis engine version"
  default     = "V7_0_5"
}
