# ===================================================================================================
# E2B on OCI - Packer Configuration
# ===================================================================================================
# Builds custom OCI image with Docker, Nomad, Consul pre-installed
# Based on AWS sample-e2b-on-aws/infra-iac/packer/main.pkr.hcl

packer {
  required_version = ">=1.9.0"
  required_plugins {
    oracle = {
      version = ">= 1.0.4"
      source  = "github.com/hashicorp/oracle"
    }
  }
}

# ===================================================================================================
# SOURCE: OCI Compute Instance Builder
# ===================================================================================================

source "oracle-oci" "e2b_base" {
  compartment_ocid    = var.compartment_ocid
  availability_domain = var.availability_domain
  subnet_ocid         = var.subnet_ocid
  
  # Base image (Ubuntu 22.04)
  base_image_ocid     = var.ubuntu_image_ocid
  
  # Build instance shape (cheap VM for building)
  shape               = var.build_shape
  shape_config {
    ocpus         = var.build_ocpus
    memory_in_gbs = var.build_memory_gb
  }
  
  # Output custom image
  image_name          = "e2b-oci-base-${formatdate("YYYY-MM-DD-hhmm", timestamp())}"
  
  # SSH configuration
  ssh_username        = "ubuntu"
}

# ===================================================================================================
# BUILD: Install Software and Configure System
# ===================================================================================================

build {
  sources = ["source.oracle-oci.e2b_base"]
  
  # -------------------------------------------------------------------------
  # Step 1: System Updates
  # -------------------------------------------------------------------------
  provisioner "shell" {
    inline = [
      "sudo apt-get clean",
      "sudo apt-get update -y",
      "sudo apt-get upgrade -y",
      "sudo DEBIAN_FRONTEND=noninteractive apt-get install -y ca-certificates curl git unzip jq net-tools qemu-utils make build-essential"
    ]
  }
  
  # -------------------------------------------------------------------------
  # Step 2: Copy Setup Files
  # -------------------------------------------------------------------------
  provisioner "file" {
    source      = "${path.root}/setup"
    destination = "/tmp"
  }
  
  # -------------------------------------------------------------------------
  # Step 3: Install Docker
  # -------------------------------------------------------------------------
  provisioner "shell" {
    inline = [
      "sudo mkdir -p /etc/docker",
      "sudo mv /tmp/setup/daemon.json /etc/docker/daemon.json",
      "curl -fsSL https://get.docker.com -o /tmp/get-docker.sh",
      "sudo sh /tmp/get-docker.sh",
      "sudo systemctl enable docker",
      "sudo systemctl start docker",
      "sudo usermod -aG docker ubuntu"
    ]
  }
  
  # -------------------------------------------------------------------------
  # Step 4: Install OCI CLI (OCI-specific)
  # -------------------------------------------------------------------------
  provisioner "shell" {
    inline = [
      "bash -c \"$(curl -L https://raw.githubusercontent.com/oracle/oci-cli/master/scripts/install/install.sh)\" -- --accept-all-defaults",
      "echo 'export PATH=$PATH:/home/ubuntu/bin' >> ~/.bashrc"
    ]
  }
  
  # -------------------------------------------------------------------------
  # Step 5: Install bash-commons (needed by Nomad/Consul scripts)
  # -------------------------------------------------------------------------
  provisioner "shell" {
    inline = [
      "sudo mkdir -p /opt/gruntwork",
      "git clone --branch v0.1.3 https://github.com/gruntwork-io/bash-commons.git /tmp/bash-commons",
      "sudo cp -r /tmp/bash-commons/modules/bash-commons/src /opt/gruntwork/bash-commons"
    ]
  }
  
  # -------------------------------------------------------------------------
  # Step 6: Install Consul (REUSE AWS SCRIPT!)
  # -------------------------------------------------------------------------
  provisioner "shell" {
    script          = "${path.root}/setup/install-consul.sh"
    execute_command = "chmod +x {{ .Path }}; {{ .Vars }} {{ .Path }} --version ${var.consul_version}"
  }
  
  # -------------------------------------------------------------------------
  # Step 7: Install Nomad (REUSE AWS SCRIPT!)
  # -------------------------------------------------------------------------
  provisioner "shell" {
    script          = "${path.root}/setup/install-nomad.sh"
    execute_command = "chmod +x {{ .Path }}; {{ .Vars }} {{ .Path }} --version ${var.nomad_version}"
  }
  
  # -------------------------------------------------------------------------
  # Step 8: Create Nomad Plugins Directory
  # -------------------------------------------------------------------------
  provisioner "shell" {
    inline = [
      "sudo mkdir -p /opt/nomad/plugins",
      "sudo chown nomad:nomad /opt/nomad/plugins"
    ]
  }
  
  # -------------------------------------------------------------------------
  # Step 9: System Tuning
  # -------------------------------------------------------------------------
  provisioner "shell" {
    inline = [
      # Increase file descriptor limits
      "sudo mv /tmp/setup/limits.conf /etc/security/limits.conf",
      
      # Increase connection tracking
      "echo 'net.netfilter.nf_conntrack_max = 2097152' | sudo tee -a /etc/sysctl.conf",
      
      # Apply sysctl settings
      "sudo sysctl -p"
    ]
  }
  
  # -------------------------------------------------------------------------
  # NOTE: Firecracker is NOT installed in base image!
  # It will be downloaded at runtime from OCI Object Storage by Orchestrator
  # -------------------------------------------------------------------------
}

