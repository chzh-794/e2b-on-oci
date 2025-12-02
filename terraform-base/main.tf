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
    random = {
      source  = "hashicorp/random"
      version = "~> 3.5"
    }
  }
}

provider "oci" {
  region = var.region
  # OCI Resource Manager injects auth via InstancePrincipal
  # Default provider for compute resources in user-specified region
}

# Provider for home region (IAM resources must be created in home region)
provider "oci" {
  alias  = "home"
  region = "us-ashburn-1"
  # OCI Resource Manager injects auth via InstancePrincipal
}

# Get compartment details to retrieve compartment name for IAM policies
data "oci_identity_compartment" "target_compartment" {
  id = var.compartment_ocid
}

# Get list of availability domains (like AWS fetches AZs)
data "oci_identity_availability_domains" "ads" {
  compartment_id = var.compartment_ocid
}

# Auto-select ADs for high availability (matches AWS behavior)
locals {
  # Use first available AD for single-instance resources (bastion)
  # For multi-instance resources (future: Nomad cluster), spread across all ADs
  availability_domain = data.oci_identity_availability_domains.ads.availability_domains[0].name
  
  # All available ADs for multi-AD deployment (cluster nodes, etc.)
  all_availability_domains = [
    for ad in data.oci_identity_availability_domains.ads.availability_domains : ad.name
  ]
  
  # Common constants
  anywhere = "0.0.0.0/0"
  tcp_protocol = "6"
  icmp_protocol = "1"
  all_protocols = "all"
  psql_is_regionally_durable = length(data.oci_identity_availability_domains.ads.availability_domains) > 1
}

# Get Ubuntu 22.04 image (used for both bastion and Packer builds)
data "oci_core_images" "ubuntu_2204_all" {
  compartment_id           = var.compartment_ocid
  operating_system         = "Canonical Ubuntu"
  operating_system_version = "22.04"
  shape                    = var.bastion_shape
  sort_by                  = "TIMECREATED"
  sort_order               = "DESC"
}

locals {
  # Detect ARM (A1) shapes vs x86 shapes by name
  # A1 shapes (e.g., VM.Standard.A1.Flex, BM.Standard.A1.160) are ARM
  # All other shapes are x86_64
  is_arm_shape = length(regexall("A1", var.bastion_shape)) > 0
  
  # Filter images based on architecture
  filtered_images = [
    for img in data.oci_core_images.ubuntu_2204_all.images :
    img if local.is_arm_shape ? 
      strcontains(lower(img.display_name), "aarch64") :
      !strcontains(lower(img.display_name), "aarch64")
  ]
  
  ubuntu_image_id   = local.filtered_images[0].id
  ubuntu_image_name = local.filtered_images[0].display_name
}

# ===================================================================================================
# SSH KEY CONFIGURATION
# ===================================================================================================

# SSH key selection logic - user must provide public key
locals {
  ssh_public_key = (
    var.ssh_public_key != null
    ? var.ssh_public_key
    : file(var.ssh_public_key_path)
  )
}

locals {
  object_storage_buckets = {
    loki_storage          = "loki-storage"
    envs_docker_context   = "envs-docker-context"
    cluster_setup         = "cluster-setup"
    fc_kernels            = "fc-kernels"
    fc_versions           = "fc-versions"
    fc_env_pipeline       = "fc-env-pipeline"
    fc_template           = "fc-template"
    docker_contexts       = "docker-contexts"
  }
}

# ===================================================================================================
# VCN AND NETWORKING
# ===================================================================================================

# Create VCN (Virtual Cloud Network) - equivalent to AWS VPC
resource "oci_core_vcn" "e2b_vcn" {
  compartment_id = var.compartment_ocid
  cidr_blocks    = [var.vcn_cidr_block]
  display_name   = "${var.prefix}-vcn"
  dns_label      = replace(var.prefix, "-", "")
}

# Create Internet Gateway - for public subnet internet access
resource "oci_core_internet_gateway" "e2b_igw" {
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.e2b_vcn.id
  display_name   = "${var.prefix}-igw"
  enabled        = true
}

# Create Route Table for public subnet
resource "oci_core_route_table" "e2b_public_rt" {
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.e2b_vcn.id
  display_name   = "${var.prefix}-public-rt"

  route_rules {
    network_entity_id = oci_core_internet_gateway.e2b_igw.id
    destination       = "0.0.0.0/0"
    destination_type  = "CIDR_BLOCK"
  }
}

# Create Security List for public subnet
resource "oci_core_security_list" "e2b_public_sl" {
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.e2b_vcn.id
  display_name   = "${var.prefix}-public-sl"

  # Allow SSH from specified CIDR
  ingress_security_rules {
    protocol    = "6" # TCP
    source      = var.allowed_ssh_cidr
    description = "SSH access to bastion"

    tcp_options {
      min = 22
      max = 22
    }
  }

  # Allow all outbound traffic
  egress_security_rules {
    protocol         = "all"
    destination      = "0.0.0.0/0"
    destination_type = "CIDR_BLOCK"
    description      = "Allow all outbound traffic"
  }
}

# Create Public Subnet
resource "oci_core_subnet" "e2b_public_subnet" {
  compartment_id      = var.compartment_ocid
  vcn_id              = oci_core_vcn.e2b_vcn.id
  cidr_block          = var.public_subnet_cidr
  display_name        = "${var.prefix}-public-subnet"
  dns_label           = "public"
  route_table_id      = oci_core_route_table.e2b_public_rt.id
  security_list_ids   = [oci_core_security_list.e2b_public_sl.id]
  prohibit_public_ip_on_vnic = false
}

# ===================================================================================================
# NAT GATEWAY AND SERVICE GATEWAY
# ===================================================================================================

# NAT Gateway - allows private subnet instances to access internet for outbound traffic
resource "oci_core_nat_gateway" "e2b_nat_gw" {
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.e2b_vcn.id
  display_name   = "${var.prefix}-nat-gw"
}

# Service Gateway - allows private subnet instances to access OCI services (Object Storage, etc.)
data "oci_core_services" "all_oci_services" {
  filter {
    name   = "name"
    values = ["All .* Services In Oracle Services Network"]
    regex  = true
  }
}

resource "oci_core_service_gateway" "e2b_service_gw" {
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.e2b_vcn.id
  display_name   = "${var.prefix}-service-gw"
  
  services {
    service_id = data.oci_core_services.all_oci_services.services[0].id
  }
}

# Route Table for private subnet (uses NAT Gateway)
resource "oci_core_route_table" "e2b_private_rt" {
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.e2b_vcn.id
  display_name   = "${var.prefix}-private-rt"

  # Default route through NAT Gateway
  route_rules {
    network_entity_id = oci_core_nat_gateway.e2b_nat_gw.id
    destination       = "0.0.0.0/0"
    destination_type  = "CIDR_BLOCK"
    description       = "Route to NAT Gateway for internet access"
  }

  # Route to OCI services through Service Gateway
  route_rules {
    network_entity_id = oci_core_service_gateway.e2b_service_gw.id
    destination       = data.oci_core_services.all_oci_services.services[0].cidr_block
    destination_type  = "SERVICE_CIDR_BLOCK"
    description       = "Route to Service Gateway for OCI services"
  }
}

# ===================================================================================================
# PRIVATE SUBNET AND SECURITY LIST
# ===================================================================================================

# Security List for Private Subnet - E2B backend services
resource "oci_core_security_list" "e2b_private_sl" {
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.e2b_vcn.id
  display_name   = "${var.prefix}-private-sl"

  # SSH from within VCN
  ingress_security_rules {
    protocol    = local.tcp_protocol
    source      = var.vcn_cidr_block
    description = "SSH from within VCN"
    tcp_options {
      min = 22
      max = 22
    }
  }

  # PostgreSQL from within VCN
  ingress_security_rules {
    protocol    = local.tcp_protocol
    source      = var.vcn_cidr_block
    description = "PostgreSQL database access"
    tcp_options {
      min = 5432
      max = 5432
    }
  }

  # Redis/Cache from within VCN
  ingress_security_rules {
    protocol    = local.tcp_protocol
    source      = var.vcn_cidr_block
    description = "Redis cache access"
    tcp_options {
      min = 6379
      max = 6379
    }
  }

  # Consul HTTP API
  ingress_security_rules {
    protocol    = local.tcp_protocol
    source      = var.vcn_cidr_block
    description = "Consul HTTP API"
    tcp_options {
      min = 8500
      max = 8500
    }
  }

  # Consul DNS
  ingress_security_rules {
    protocol    = local.tcp_protocol
    source      = var.vcn_cidr_block
    description = "Consul DNS"
    tcp_options {
      min = 8600
      max = 8600
    }
  }

  # Orchestrator gRPC (mirrors AWS SG default allow-from-VPC policy)
  ingress_security_rules {
    protocol    = local.tcp_protocol
    source      = var.vcn_cidr_block
    description = "Allow orchestrator gRPC traffic"
    tcp_options {
      min = 5008
      max = 5008
    }
  }

  # Template-manager gRPC
  ingress_security_rules {
    protocol    = local.tcp_protocol
    source      = var.vcn_cidr_block
    description = "Allow template-manager gRPC traffic"
    tcp_options {
      min = 5009
      max = 5009
    }
  }

  # ICMP for path discovery
  ingress_security_rules {
    protocol    = local.icmp_protocol
    source      = var.vcn_cidr_block
    description = "ICMP for path MTU discovery"
    icmp_options {
      type = 3
      code = 4
    }
  }

  ingress_security_rules {
    protocol    = local.icmp_protocol
    source      = var.vcn_cidr_block
    source_type = "CIDR_BLOCK"
    description = "Allow ICMP traffic within the VCN"
  }

  # Allow all egress (TODO: tighten after POC once a controlled mirror is available)
  egress_security_rules {
    protocol         = local.all_protocols
    destination      = local.anywhere
    destination_type = "CIDR_BLOCK"
    description      = "POC fallback: allow outbound internet so private nodes can reach package mirrors"
  }

  # TODO: Remove after POC – explicit HTTP/HTTPS egress rule to document why internet access is required
  egress_security_rules {
    protocol         = local.tcp_protocol
    destination      = "0.0.0.0/0"
    destination_type = "CIDR_BLOCK"
    description      = "Temporary POC rule: apt mirrors over HTTP/HTTPS for offline images"

    tcp_options {
      min = 80
      max = 80
    }
  }

  # TODO: Remove after POC – HTTPS egress
  egress_security_rules {
    protocol         = local.tcp_protocol
    destination      = "0.0.0.0/0"
    destination_type = "CIDR_BLOCK"
    description      = "Temporary POC rule: apt mirrors over HTTPS for offline images"

    tcp_options {
      min = 443
      max = 443
    }
  }
}


# Private Subnet - for backend services (DB, Redis, Nomad servers, etc.)
resource "oci_core_subnet" "e2b_private_subnet" {
  compartment_id             = var.compartment_ocid
  vcn_id                     = oci_core_vcn.e2b_vcn.id
  cidr_block                 = var.private_subnet_cidr
  display_name               = "${var.prefix}-private-subnet"
  dns_label                  = "private"
  route_table_id             = oci_core_route_table.e2b_private_rt.id
  security_list_ids          = [oci_core_security_list.e2b_private_sl.id]
  prohibit_public_ip_on_vnic = true
}

# ===================================================================================================
# NETWORK SECURITY GROUPS FOR MANAGED SERVICES
# ===================================================================================================

resource "oci_core_network_security_group" "services_nsg" {
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.e2b_vcn.id
  display_name   = "${var.prefix}-services-nsg"
}

resource "oci_core_network_security_group_security_rule" "services_postgres_ingress" {
  network_security_group_id = oci_core_network_security_group.services_nsg.id
  direction                 = "INGRESS"
  protocol                  = "6"

  tcp_options {
    destination_port_range {
      min = 5432
      max = 5432
    }
  }

  source      = var.vcn_cidr_block
  source_type = "CIDR_BLOCK"
  description = "Allow PostgreSQL access from VCN"
}

resource "oci_core_network_security_group_security_rule" "services_redis_ingress" {
  network_security_group_id = oci_core_network_security_group.services_nsg.id
  direction                 = "INGRESS"
  protocol                  = "6"

  tcp_options {
    destination_port_range {
      min = 6379
      max = 6379
    }
  }

  source      = var.vcn_cidr_block
  source_type = "CIDR_BLOCK"
  description = "Allow Redis access from VCN"
}

resource "oci_core_network_security_group_security_rule" "services_egress" {
  network_security_group_id = oci_core_network_security_group.services_nsg.id
  direction                 = "EGRESS"
  protocol                  = "all"
  destination               = "0.0.0.0/0"
  destination_type          = "CIDR_BLOCK"
  description               = "Allow all egress"
}

# ===================================================================================================
# LOAD BALANCER SUBNETS (Regional Subnets)
# ===================================================================================================

# Security List for Public Load Balancer
resource "oci_core_security_list" "e2b_public_lb_sl" {
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.e2b_vcn.id
  display_name   = "${var.prefix}-public-lb-sl"

  # HTTP from internet
  ingress_security_rules {
    protocol    = local.tcp_protocol
    source      = local.anywhere
    description = "HTTP from internet"
    tcp_options {
      min = 80
      max = 80
    }
  }

  # HTTPS from internet
  ingress_security_rules {
    protocol    = local.tcp_protocol
    source      = local.anywhere
    description = "HTTPS from internet"
    tcp_options {
      min = 443
      max = 443
    }
  }

  # Allow all egress for health checks to backend
  egress_security_rules {
    protocol         = local.all_protocols
    destination      = var.vcn_cidr_block
    destination_type = "CIDR_BLOCK"
    description      = "Allow traffic to backend services"
  }
}

# Public Load Balancer Subnet
resource "oci_core_subnet" "e2b_public_lb_subnet" {
  count                      = var.create_load_balancer ? 1 : 0
  compartment_id             = var.compartment_ocid
  vcn_id                     = oci_core_vcn.e2b_vcn.id
  cidr_block                 = var.public_lb_subnet_cidr
  display_name               = "${var.prefix}-public-lb-subnet"
  dns_label                  = "publb"
  route_table_id             = oci_core_route_table.e2b_public_rt.id
  security_list_ids          = [oci_core_security_list.e2b_public_lb_sl.id]
  prohibit_public_ip_on_vnic = false
}

# ===================================================================================================
# ENHANCED PUBLIC SECURITY LIST (Add E2B service rules)
# ===================================================================================================

# Update public security list to include E2B API and service ports
# ===================================================================================================
# IAM: DYNAMIC GROUP AND POLICY FOR BASTION
# ===================================================================================================

# Dynamic group for bastion instance to use instance principal auth (created in home region)
resource "oci_identity_dynamic_group" "service_dynamic_group" {
  provider       = oci.home
  compartment_id = var.tenancy_ocid
  name           = "${var.prefix}-service-dynamic-group"
  description    = "E2B service instances within the compartment (bastion, clusters, managed services)"
  matching_rule  = "instance.compartment.id = '${var.compartment_ocid}'"
}

# Policy to allow bastion to manage compute resources for Packer
# Following agent-shepherd pattern: policy created in the compartment (not at tenancy root)
# Dynamic group is at tenancy root, but policy is in the compartment where resources are managed
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
    "Allow dynamic-group ${oci_identity_dynamic_group.service_dynamic_group.name} to manage buckets in compartment ${data.oci_identity_compartment.target_compartment.name}"
  ]
}

# ===================================================================================================
# BASTION INSTANCE
# ===================================================================================================

# Bastion instance - equivalent to AWS Bastion EC2
resource "oci_core_instance" "bastion" {
  compartment_id      = var.compartment_ocid
  availability_domain = local.availability_domain
  display_name        = "${var.prefix}-bastion"
  shape               = var.bastion_shape

  shape_config {
    ocpus         = var.bastion_ocpus
    memory_in_gbs = var.bastion_memory_in_gbs
  }

  source_details {
    source_type = "image"
    source_id   = local.ubuntu_image_id
  }

  create_vnic_details {
    subnet_id        = oci_core_subnet.e2b_public_subnet.id
    assign_public_ip = true
    display_name     = "${var.prefix}-bastion-vnic"
  }

  metadata = {
    ssh_authorized_keys = local.ssh_public_key
    user_data           = base64encode(templatefile("${path.module}/bastion-init.sh", {
      ENVIRONMENT        = var.environment
      PREFIX             = var.prefix
      COMPARTMENT_OCID   = var.compartment_ocid
      REGION             = var.region
      SUBNET_OCID        = oci_core_subnet.e2b_public_subnet.id
      AD                 = local.availability_domain
      UBUNTU_IMAGE_OCID  = local.ubuntu_image_id
      ARCH               = local.is_arm_shape ? "aarch64" : "x86_64"
      HASH_ARCH          = local.is_arm_shape ? "arm64" : "amd64"
    }))
  }
  

  # Prevent accidental deletion in prod
  lifecycle {
    prevent_destroy = false
  }
}

# ===================================================================================================
# OBJECT STORAGE BUCKETS
# ===================================================================================================

module "object_storage_buckets" {
  for_each       = var.enable_object_storage ? local.object_storage_buckets : {}
  source         = "./modules/object_storage_bucket"
  compartment_id = var.compartment_ocid
  bucket_name    = each.value
}

# ===================================================================================================
# CONTAINER REGISTRY (OCIR)
# ===================================================================================================

data "oci_objectstorage_namespace" "ocir" {
  compartment_id = var.compartment_ocid
}

# Container Registry repository for template images
# NOTE: display_name must be unique across the tenancy
resource "oci_artifacts_container_repository" "template_registry" {
  compartment_id = var.compartment_ocid
  display_name   = "${var.prefix}-templates"  # you can also hardcode "e2b-templates" if you want it stable
  is_public      = false
  is_immutable   = false

  # Optional but nice to have
  freeform_tags = {
    "app"         = "e2b"
    "environment" = var.environment
  }
}

# ===================================================================================================
# POSTGRESQL (MANAGED SERVICE)
# ===================================================================================================

module "postgresql" {
  count             = var.enable_postgresql ? 1 : 0
  source            = "./modules/oci_postgresql"
  compartment_id    = var.compartment_ocid
  display_name      = "${var.prefix}-postgresql-db"
  db_username       = "admin"
  db_password       = var.postgresql_admin_password
  db_version        = var.postgresql_db_version
  subnet_id         = oci_core_subnet.e2b_private_subnet.id
  nsg_ids           = [oci_core_network_security_group.services_nsg.id]
  instance_count    = var.postgresql_instance_count
  instance_memory_gbs   = var.postgresql_instance_memory_gbs
  instance_ocpu_count   = var.postgresql_instance_ocpus
  iops                = var.postgresql_iops
  is_regionally_durable = local.psql_is_regionally_durable
  storage_availability_domain = local.psql_is_regionally_durable ? null : local.availability_domain
  freeform_tags       = {}
  defined_tags        = {}
}

# ===================================================================================================
# REDIS (OCI CACHE)
# ===================================================================================================

module "redis_cluster" {
  count             = var.enable_redis ? 1 : 0
  source            = "./modules/oci_redis"
  compartment_id    = var.compartment_ocid
  display_name      = "envd-cache"
  node_count        = var.redis_node_count
  node_memory_in_gbs = var.redis_node_memory_gbs
  software_version  = var.redis_software_version
  subnet_id         = oci_core_subnet.e2b_private_subnet.id
  nsg_ids           = [oci_core_network_security_group.services_nsg.id]
  cluster_mode      = "NONSHARDED"
}

