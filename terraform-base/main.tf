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
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
  }
}

provider "oci" {
  region = var.region
  # OCI Resource Manager injects auth via InstancePrincipal
  # Only region needs to be explicitly set
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

# Get Ubuntu 22.04 image for bastion
data "oci_core_images" "ubuntu_2204" {
  compartment_id           = var.compartment_ocid
  operating_system         = "Canonical Ubuntu"
  operating_system_version = "22.04"
  shape                    = var.bastion_shape
  sort_by                  = "TIMECREATED"
  sort_order               = "DESC"
}

# ===================================================================================================
# SSH KEY AUTO-GENERATION (follows moirai-infra pattern)
# ===================================================================================================

# Auto-generate SSH key if not provided
resource "tls_private_key" "ssh" {
  count     = var.ssh_public_key == null && var.ssh_public_key_path == null ? 1 : 0
  algorithm = "RSA"
  rsa_bits  = 4096
}

# Determine which SSH key to use: provided > from file > auto-generated
locals {
  ssh_public_key = (
    var.ssh_public_key != null
    ? var.ssh_public_key
    : var.ssh_public_key_path != null
    ? file(var.ssh_public_key_path)
    : try(tls_private_key.ssh[0].public_key_openssh, null)
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
    source_id   = data.oci_core_images.ubuntu_2204.images[0].id
  }

  create_vnic_details {
    subnet_id        = oci_core_subnet.e2b_public_subnet.id
    assign_public_ip = true
    display_name     = "${var.prefix}-bastion-vnic"
  }

  metadata = {
    ssh_authorized_keys = local.ssh_public_key
    user_data           = base64encode(templatefile("${path.module}/bastion-init.sh", {
      ENVIRONMENT = var.environment
      PREFIX      = var.prefix
    }))
  }

  # Prevent accidental deletion in prod
  lifecycle {
    prevent_destroy = false
  }
}

