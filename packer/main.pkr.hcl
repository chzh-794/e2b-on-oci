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
  # Use instance principal authentication (bastion must be in dynamic group with IAM policy)
  # CRITICAL: Must be string "true", not boolean, per packer-plugin-oracle examples
  use_instance_principals = "true"
  
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
  # Step 1: Wait for cloud-init and System Updates
  # -------------------------------------------------------------------------
  provisioner "shell" {
    inline = [
      "echo 'Waiting for cloud-init to finish...'",
      "cloud-init status --wait || true",
      "echo 'Waiting for apt locks to be released...'",
      "while sudo fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1 || sudo fuser /var/lib/apt/lists/lock >/dev/null 2>&1; do echo 'Waiting for apt lock...'; sleep 5; done",
      "sudo apt-get clean",
      "sudo apt-get update -y",
      "sudo DEBIAN_FRONTEND=noninteractive apt-get upgrade -y",
      "sudo DEBIAN_FRONTEND=noninteractive apt-get install -y ca-certificates curl git unzip jq net-tools qemu-utils || true",
      "sudo apt-get update -y",
      "sudo DEBIAN_FRONTEND=noninteractive apt-get install -y make build-essential || true"
    ]
  }
  
  # -------------------------------------------------------------------------
  # Step 2: Copy Setup Files
  # -------------------------------------------------------------------------
  # Upload supervisord.conf separately for install-nomad.sh (AWS pattern)
  provisioner "file" {
    source      = "${path.root}/setup/supervisord.conf"
    destination = "/tmp/supervisord.conf"
  }
  
  provisioner "file" {
    source      = "${path.root}/setup"
    destination = "/tmp"
  }
  
  provisioner "file" {
    source      = "${path.root}/setup/daemon.json"
    destination = "/tmp/daemon.json"
  }
  
  provisioner "file" {
    source      = "${path.root}/setup/limits.conf"
    destination = "/tmp/limits.conf"
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
  # Step 4: Install additional packages (openssh-server for security)
  # -------------------------------------------------------------------------
  provisioner "shell" {
    inline = [
      "sudo apt-get update",
      "sudo DEBIAN_FRONTEND=noninteractive apt-get install -y openssh-client openssh-server"
    ]
  }
  
  # -------------------------------------------------------------------------
  # Step 5: Install OCI CLI (OCI-specific, equivalent to AWS CLI)
  # -------------------------------------------------------------------------
  provisioner "shell" {
    inline = [
      "bash -c \"$(curl -L https://raw.githubusercontent.com/oracle/oci-cli/master/scripts/install/install.sh)\" -- --accept-all-defaults",
      "echo 'export PATH=$PATH:/home/ubuntu/bin' >> ~/.bashrc"
    ]
  }
  
  # -------------------------------------------------------------------------
  # Step 6: Install Go (for building E2B components)
  # -------------------------------------------------------------------------
  provisioner "shell" {
    inline = [
      "sudo DEBIAN_FRONTEND=noninteractive snap install go --classic"
    ]
  }
  
  # -------------------------------------------------------------------------
  # Step 7: Install bash-commons (needed by Nomad/Consul scripts)
  # -------------------------------------------------------------------------
  provisioner "shell" {
    inline = [
      "sudo mkdir -p /opt/gruntwork",
      "git clone --branch v0.1.3 https://github.com/gruntwork-io/bash-commons.git /tmp/bash-commons",
      "sudo cp -r /tmp/bash-commons/modules/bash-commons/src /opt/gruntwork/bash-commons"
    ]
  }
  
  # -------------------------------------------------------------------------
  # Step 7.5: Ensure apt locks are released before installing Consul/Nomad
  # -------------------------------------------------------------------------
  provisioner "shell" {
    inline = [
      "echo 'Ensuring apt locks are released before Consul/Nomad install...'",
      "while sudo fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1 || sudo fuser /var/lib/apt/lists/lock >/dev/null 2>&1; do echo 'Waiting for apt lock before Consul/Nomad install...'; sleep 5; done",
      "sudo apt-get update -y"
    ]
  }

  # -------------------------------------------------------------------------
  # Step 8: Install Consul (REUSE AWS SCRIPT!)
  # -------------------------------------------------------------------------
  provisioner "shell" {
    script          = "${path.root}/setup/install-consul.sh"
    execute_command = "chmod +x {{ .Path }}; {{ .Vars }} {{ .Path }} --version ${var.consul_version}"
  }
  
  # -------------------------------------------------------------------------
  # Step 9: Install Nomad (REUSE AWS SCRIPT!)
  # -------------------------------------------------------------------------
  provisioner "shell" {
    script          = "${path.root}/setup/install-nomad.sh"
    execute_command = "chmod +x {{ .Path }}; cp /tmp/supervisord.conf $(dirname {{ .Path }})/; {{ .Vars }} {{ .Path }} --version ${var.nomad_version}"
  }
  
  # -------------------------------------------------------------------------
  # Step 10: Create Nomad Plugins Directory
  # -------------------------------------------------------------------------
  provisioner "shell" {
    inline = [
      "sudo mkdir -p /opt/nomad/plugins",
      "sudo chown nomad:nomad /opt/nomad/plugins"
    ]
  }
  
  # -------------------------------------------------------------------------
  # Step 11: System Tuning
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

