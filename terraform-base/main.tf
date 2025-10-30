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
  region = "us-phoenix-1"
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
  
  # All available ADs for future use (cluster nodes, etc.)
  all_availability_domains = [
    for ad in data.oci_identity_availability_domains.ads.availability_domains : ad.name
  ]
}

# Get x86_64 Ubuntu 22.04 image (used for both bastion and Packer builds)
data "oci_core_images" "ubuntu_2204_all" {
  compartment_id           = var.compartment_ocid
  operating_system         = "Canonical Ubuntu"
  operating_system_version = "22.04"
  sort_by                  = "TIMECREATED"
  sort_order               = "DESC"
}

locals {
  # Filter out aarch64 images - only use x86_64
  x86_images = [
    for img in data.oci_core_images.ubuntu_2204_all.images :
    img if !strcontains(img.display_name, "aarch64")
  ]
  ubuntu_image_id   = local.x86_images[0].id
  ubuntu_image_name = local.x86_images[0].display_name
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

# ===================================================================================================
# DATABASE PASSWORD AUTO-GENERATION (follows agent-shepherd pattern)
# ===================================================================================================

# Auto-generate strong password for PostgreSQL/ADB
# Format: E2B_/lowercaseUPPERCASE123aZ!
# Guarantees: uppercase, lowercase, numbers, special chars
locals {
  db_admin_password = format("%s/%s", "E2B_", 
    replace("${lower(substr(uuid(), 0, 10))}${upper(substr(uuid(), 0, 10))}aZ!", "-", "9"))
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
# IAM: DYNAMIC GROUP AND POLICY FOR BASTION
# ===================================================================================================

# Dynamic group for bastion instance to use instance principal auth (created in home region)
resource "oci_identity_dynamic_group" "bastion_dynamic_group" {
  provider       = oci.home
  compartment_id = var.tenancy_ocid
  name           = "${var.prefix}-bastion-dynamic-group"
  description    = "E2B bastion instance for Packer builds"
  matching_rule  = "instance.compartment.id = '${var.compartment_ocid}'"
}

# Policy to allow bastion to manage compute resources for Packer
# Following agent-shepherd pattern: policy created in the compartment (not at tenancy root)
# Dynamic group is at tenancy root, but policy is in the compartment where resources are managed
resource "oci_identity_policy" "bastion_policy" {
  provider       = oci.home
  compartment_id = var.compartment_ocid
  name           = "${var.prefix}-bastion-policy"
  description    = "Policy for E2B bastion to manage compute resources via Packer"
  
  statements = [
    "Allow dynamic-group ${oci_identity_dynamic_group.bastion_dynamic_group.name} to manage instance-family in compartment ${data.oci_identity_compartment.target_compartment.name}",
    "Allow dynamic-group ${oci_identity_dynamic_group.bastion_dynamic_group.name} to manage compute-image-capability-schema in compartment ${data.oci_identity_compartment.target_compartment.name}",
    "Allow dynamic-group ${oci_identity_dynamic_group.bastion_dynamic_group.name} to manage volume-family in compartment ${data.oci_identity_compartment.target_compartment.name}",
    "Allow dynamic-group ${oci_identity_dynamic_group.bastion_dynamic_group.name} to manage virtual-network-family in compartment ${data.oci_identity_compartment.target_compartment.name}",
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
    }))
  }
  

  # Prevent accidental deletion in prod
  lifecycle {
    prevent_destroy = false
  }
}

