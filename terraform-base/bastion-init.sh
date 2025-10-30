#!/bin/bash
# ===================================================================================================
# E2B on OCI - Bastion Initialization Script
# ===================================================================================================
# This script runs on first boot via cloud-init
# Similar to AWS CloudFormation UserData

set -e

# Passed from Terraform via templatefile()
ENVIRONMENT="${ENVIRONMENT}"
PREFIX="${PREFIX}"
COMPARTMENT_OCID="${COMPARTMENT_OCID}"
REGION="${REGION}"
SUBNET_OCID="${SUBNET_OCID}"
AD="${AD}"
UBUNTU_IMAGE_OCID="${UBUNTU_IMAGE_OCID}"

LOG_FILE="/var/log/e2b-init.log"

echo "====================================================================================================" | tee -a $LOG_FILE
echo "E2B on OCI - Bastion Initialization Started" | tee -a $LOG_FILE
echo "Time: $(date)" | tee -a $LOG_FILE
echo "Environment: $ENVIRONMENT" | tee -a $LOG_FILE
echo "Prefix: $PREFIX" | tee -a $LOG_FILE
echo "Region: $REGION (auto-detected)" | tee -a $LOG_FILE
echo "====================================================================================================" | tee -a $LOG_FILE

# Wait for cloud-init's automatic apt updates to finish
echo "Waiting for cloud-init to finish..." | tee -a $LOG_FILE
while sudo fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1 || sudo fuser /var/lib/apt/lists/lock >/dev/null 2>&1; do
  echo "Waiting for apt lock to be released..." | tee -a $LOG_FILE
  sleep 5
done

# Update system
echo "Updating system packages..." | tee -a $LOG_FILE
export DEBIAN_FRONTEND=noninteractive
apt-get update -y >> $LOG_FILE 2>&1
apt-get upgrade -y >> $LOG_FILE 2>&1

# Install basic tools
echo "Installing basic tools..." | tee -a $LOG_FILE
apt-get install -y \
  curl \
  wget \
  git \
  unzip \
  jq \
  build-essential \
  ca-certificates >> $LOG_FILE 2>&1

# Install Docker
echo "Installing Docker..." | tee -a $LOG_FILE
curl -fsSL https://get.docker.com -o /tmp/get-docker.sh >> $LOG_FILE 2>&1
sh /tmp/get-docker.sh >> $LOG_FILE 2>&1
systemctl enable docker >> $LOG_FILE 2>&1
systemctl start docker >> $LOG_FILE 2>&1
usermod -aG docker ubuntu >> $LOG_FILE 2>&1

# Install OCI CLI
echo "Installing OCI CLI..." | tee -a $LOG_FILE
bash -c "$(curl -L https://raw.githubusercontent.com/oracle/oci-cli/master/scripts/install/install.sh)" -- --accept-all-defaults >> $LOG_FILE 2>&1

# Install Packer
echo "Installing Packer..." | tee -a $LOG_FILE
wget -q https://releases.hashicorp.com/packer/1.10.0/packer_1.10.0_linux_amd64.zip -O /tmp/packer.zip >> $LOG_FILE 2>&1
unzip -q /tmp/packer.zip -d /tmp >> $LOG_FILE 2>&1
sudo mv /tmp/packer /usr/local/bin/packer >> $LOG_FILE 2>&1
rm /tmp/packer.zip

# Install Terraform
echo "Installing Terraform..." | tee -a $LOG_FILE
wget -q https://releases.hashicorp.com/terraform/1.5.7/terraform_1.5.7_linux_amd64.zip -O /tmp/terraform.zip >> $LOG_FILE 2>&1
unzip -q /tmp/terraform.zip -d /tmp >> $LOG_FILE 2>&1
sudo mv /tmp/terraform /usr/local/bin/terraform >> $LOG_FILE 2>&1
rm /tmp/terraform.zip

# Clone/Update E2B OCI repository
echo "Cloning/Updating E2B on OCI repository..." | tee -a $LOG_FILE
mkdir -p /opt/e2b && cd /opt/e2b
if [ -d "e2b-on-oci" ]; then
  echo "Repository exists, pulling latest changes..." | tee -a $LOG_FILE
  cd e2b-on-oci
  git fetch origin >> $LOG_FILE 2>&1
  git reset --hard origin/main >> $LOG_FILE 2>&1
else
  echo "Cloning repository..." | tee -a $LOG_FILE
  git clone https://github.com/chzh-794/e2b-on-oci.git >> $LOG_FILE 2>&1
  cd e2b-on-oci
fi

# Wait for CloudFormation to complete (similar to AWS pattern)
# In OCI, we wait for Resource Manager stack to be fully ready
echo "Waiting for Resource Manager stack to complete..." | tee -a $LOG_FILE
sleep 30

echo "========================================" | tee -a $LOG_FILE
echo "Starting Packer build..." | tee -a $LOG_FILE
echo "========================================" | tee -a $LOG_FILE

cd /opt/e2b/e2b-on-oci/packer

echo "Packer variables (passed from Terraform):" | tee -a $LOG_FILE
echo "Compartment: $COMPARTMENT_OCID" | tee -a $LOG_FILE
echo "Region: $REGION" | tee -a $LOG_FILE
echo "Subnet: $SUBNET_OCID" | tee -a $LOG_FILE
echo "AD: $AD" | tee -a $LOG_FILE
echo "Ubuntu image (x86_64): $UBUNTU_IMAGE_OCID" | tee -a $LOG_FILE

# Create packer variables file automatically
cat > packer.auto.pkrvars.hcl <<EOF
compartment_ocid    = "$COMPARTMENT_OCID"
availability_domain = "$AD"
subnet_ocid         = "$SUBNET_OCID"
ubuntu_image_ocid   = "$UBUNTU_IMAGE_OCID"
consul_version      = "1.16.2"
nomad_version       = "1.6.2"
EOF

# Initialize Packer
echo "Initializing Packer..." | tee -a $LOG_FILE
packer init . >> $LOG_FILE 2>&1

# Build custom image
echo "========================================" | tee -a $LOG_FILE
echo "Starting Packer build (takes ~25 minutes)..." | tee -a $LOG_FILE
echo "========================================" | tee -a $LOG_FILE
packer build . >> $LOG_FILE 2>&1

if [ $? -eq 0 ]; then
  echo "Packer build completed successfully!" | tee -a $LOG_FILE
  # Extract image OCID from packer output
  CUSTOM_IMAGE_OCID=$(grep "An image was created" $LOG_FILE | tail -1 | grep -oP "ocid1\.image\.[a-z0-9\.\-]+")
  echo "Custom Image OCID: $CUSTOM_IMAGE_OCID" | tee -a $LOG_FILE
  echo "$CUSTOM_IMAGE_OCID" > /opt/e2b/custom_image_ocid.txt
else
  echo "Packer build failed! Check logs for details." | tee -a $LOG_FILE
fi

echo "========================================" | tee -a $LOG_FILE

# TODO: Phase 3 - Deploy Nomad cluster with custom image
# cd /opt/e2b/e2b-on-oci/terraform-cluster
# terraform init >> $LOG_FILE 2>&1
# terraform apply -auto-approve >> $LOG_FILE 2>&1

echo "====================================================================================================" | tee -a $LOG_FILE
echo "E2B on OCI - Deployment Completed" | tee -a $LOG_FILE
echo "Repository: https://github.com/chzh-794/e2b-on-oci.git" | tee -a $LOG_FILE
echo "Custom image OCID saved to: /opt/e2b/custom_image_ocid.txt" | tee -a $LOG_FILE
echo "Time: $(date)" | tee -a $LOG_FILE
echo "====================================================================================================" | tee -a $LOG_FILE
echo "" | tee -a $LOG_FILE
echo "Next steps:" | tee -a $LOG_FILE
echo "1. Check custom image in OCI Console: Compute → Custom Images" | tee -a $LOG_FILE
echo "2. Verify image OCID: cat /opt/e2b/custom_image_ocid.txt" | tee -a $LOG_FILE
echo "3. Ready for Phase 3: Deploy Nomad cluster using custom image" | tee -a $LOG_FILE
echo "====================================================================================================" | tee -a $LOG_FILE

