terraform {
  required_version = ">= 1.0"

  required_providers {
    oci = {
      source  = "oracle/oci"
      version = "~> 5.0"
    }
  }
}

provider "oci" {
  region = var.region
}

data "oci_identity_availability_domains" "ads" {
  compartment_id = var.compartment_ocid
}

locals {
  consul_run_script_b64 = filebase64("${path.module}/scripts/run-consul.sh.gz")
  nomad_run_script_b64  = filebase64("${path.module}/scripts/run-nomad.sh.gz")
  consul_client_run_script_b64 = filebase64("${path.module}/scripts/run-consul-client.sh.gz")
  nomad_client_run_script_b64  = filebase64("${path.module}/scripts/run-nomad-client.sh.gz")
  udp_protocol          = "17"

  availability_domains = [
    for ad in data.oci_identity_availability_domains.ads.availability_domains : ad.name
  ]

  cluster_defaults = {
    server = {
      display_name = "${var.prefix}-server-cluster"
      size         = var.server_desired_capacity
      shape        = var.server_shape
      ocpus        = var.server_ocpus
      memory       = var.server_memory_in_gbs
    }
    api = {
      display_name = "${var.prefix}-api-cluster"
      size         = var.api_desired_capacity
      shape        = var.api_shape
      ocpus        = var.api_ocpus
      memory       = var.api_memory_in_gbs
    }
    client = {
      display_name = "${var.prefix}-client-cluster"
      size         = var.client_desired_capacity
      shape        = var.client_shape
      ocpus        = var.client_ocpus
      memory       = var.client_memory_in_gbs
    }
  }

  instance_user_data = {
    server = base64encode(templatefile("${path.module}/templates/server-user-data.sh.tmpl", {
      environment                 = var.environment
      prefix                      = var.prefix
      consul_gossip_encryption_key = var.consul_gossip_encryption_key
      region                       = var.region
      compartment_id               = var.compartment_ocid
      cluster_size                 = local.cluster_defaults.server.size
      consul_run_script_b64        = local.consul_run_script_b64
      nomad_run_script_b64         = local.nomad_run_script_b64
      consul_client_run_script_b64 = local.consul_client_run_script_b64
      nomad_client_run_script_b64  = local.nomad_client_run_script_b64
      auto_bootstrap               = var.auto_bootstrap
    }))
    api = base64encode(templatefile("${path.module}/templates/api-user-data.sh.tmpl", {
      environment                 = var.environment
      prefix                      = var.prefix
      region                      = var.region
      compartment_id              = var.compartment_ocid
      consul_gossip_encryption_key = var.consul_gossip_encryption_key
      consul_run_script_b64        = local.consul_run_script_b64
      consul_client_run_script_b64 = local.consul_client_run_script_b64
      nomad_run_script_b64         = local.nomad_run_script_b64
      nomad_client_run_script_b64  = local.nomad_client_run_script_b64
      cluster_size                 = local.cluster_defaults.server.size
      auto_bootstrap               = var.auto_bootstrap
    }))
    client = base64encode(templatefile("${path.module}/templates/client-user-data.sh.tmpl", {
      environment                 = var.environment
      prefix                      = var.prefix
      region                      = var.region
      compartment_id              = var.compartment_ocid
      consul_gossip_encryption_key = var.consul_gossip_encryption_key
      consul_run_script_b64        = local.consul_run_script_b64
      consul_client_run_script_b64 = local.consul_client_run_script_b64
      nomad_run_script_b64         = local.nomad_run_script_b64
      nomad_client_run_script_b64  = local.nomad_client_run_script_b64
      cluster_size                 = local.cluster_defaults.server.size
      auto_bootstrap               = var.auto_bootstrap
    }))
  }
}

# ===================================================================================================
# NETWORK SECURITY GROUPS
# ===================================================================================================

resource "oci_core_network_security_group" "server" {
  compartment_id = var.compartment_ocid
  vcn_id         = var.vcn_id
  display_name   = "${var.prefix}-server-nsg"
}

resource "oci_core_network_security_group_security_rule" "server_consul_ingress" {
  network_security_group_id = oci_core_network_security_group.server.id
  direction                 = "INGRESS"
  protocol                  = "6"

  tcp_options {
    destination_port_range {
      min = 8300
      max = 8302
    }
  }

  source      = var.vcn_cidr_block
  source_type = "CIDR_BLOCK"
  description = "Consul server ports"
}

resource "oci_core_network_security_group_security_rule" "server_consul_udp_ingress" {
  network_security_group_id = oci_core_network_security_group.server.id
  direction                 = "INGRESS"
  protocol                  = local.udp_protocol

  udp_options {
    destination_port_range {
      min = 8301
      max = 8302
    }
  }

  source      = var.vcn_cidr_block
  source_type = "CIDR_BLOCK"
  description = "Consul gossip (UDP)"
}

resource "oci_core_network_security_group_security_rule" "server_nomad_ingress" {
  network_security_group_id = oci_core_network_security_group.server.id
  direction                 = "INGRESS"
  protocol                  = "6"

  tcp_options {
    destination_port_range {
      min = 4646
      max = 4646
    }
  }

  source      = var.vcn_cidr_block
  source_type = "CIDR_BLOCK"
  description = "Nomad server RPC"
}

resource "oci_core_network_security_group_security_rule" "server_nomad_ingress_rpc" {
  network_security_group_id = oci_core_network_security_group.server.id
  direction                 = "INGRESS"
  protocol                  = "6"

  tcp_options {
    destination_port_range {
      min = 4647
      max = 4648
    }
  }

  source      = var.vcn_cidr_block
  source_type = "CIDR_BLOCK"
  description = "Nomad RPC/Serf TCP"
}

resource "oci_core_network_security_group_security_rule" "server_nomad_udp_ingress" {
  network_security_group_id = oci_core_network_security_group.server.id
  direction                 = "INGRESS"
  protocol                  = local.udp_protocol

  udp_options {
    destination_port_range {
      min = 4647
      max = 4648
    }
  }

  source      = var.vcn_cidr_block
  source_type = "CIDR_BLOCK"
  description = "Nomad gossip (UDP)"
}

resource "oci_core_network_security_group_security_rule" "server_all_egress" {
  network_security_group_id = oci_core_network_security_group.server.id
  direction                 = "EGRESS"
  protocol                  = "all"
  destination               = "0.0.0.0/0"
  destination_type          = "CIDR_BLOCK"
  description               = "Allow all outbound traffic"
}

resource "oci_core_network_security_group_security_rule" "server_icmp_ingress" {
  network_security_group_id = oci_core_network_security_group.server.id
  direction                 = "INGRESS"
  protocol                  = "1"
  source                    = var.vcn_cidr_block
  source_type               = "CIDR_BLOCK"
  description               = "Allow ICMP within VCN"

  icmp_options {
    type = 3
    code = 4
  }
}

resource "oci_core_network_security_group_security_rule" "server_api_port" {
  network_security_group_id = oci_core_network_security_group.server.id
  direction                 = "INGRESS"
  protocol                  = "6"

  tcp_options {
    destination_port_range {
      min = 50001
      max = 50001
    }
  }

  source      = var.vcn_cidr_block
  source_type = "CIDR_BLOCK"
  description = "E2B API"
}

resource "oci_core_network_security_group_security_rule" "server_orchestrator_port" {
  network_security_group_id = oci_core_network_security_group.server.id
  direction                 = "INGRESS"
  protocol                  = "6"

  tcp_options {
    destination_port_range {
      min = 5008
      max = 5008
    }
  }

  source      = var.vcn_cidr_block
  source_type = "CIDR_BLOCK"
  description = "Orchestrator gRPC"
}

resource "oci_core_network_security_group_security_rule" "server_orchestrator_proxy" {
  network_security_group_id = oci_core_network_security_group.server.id
  direction                 = "INGRESS"
  protocol                  = "6"

  tcp_options {
    destination_port_range {
      min = 5007
      max = 5007
    }
  }

  source      = var.vcn_cidr_block
  source_type = "CIDR_BLOCK"
  description = "Orchestrator proxy"
}

resource "oci_core_network_security_group_security_rule" "server_template_manager_port" {
  network_security_group_id = oci_core_network_security_group.server.id
  direction                 = "INGRESS"
  protocol                  = "6"

  tcp_options {
    destination_port_range {
      min = 5009
      max = 5009
    }
  }

  source      = var.vcn_cidr_block
  source_type = "CIDR_BLOCK"
  description = "Template manager gRPC"
}

resource "oci_core_network_security_group_security_rule" "server_template_manager_proxy" {
  network_security_group_id = oci_core_network_security_group.server.id
  direction                 = "INGRESS"
  protocol                  = "6"

  tcp_options {
    destination_port_range {
      min = 15007
      max = 15007
    }
  }

  source      = var.vcn_cidr_block
  source_type = "CIDR_BLOCK"
  description = "Template manager proxy"
}

resource "oci_core_network_security_group_security_rule" "server_client_proxy_ports" {
  network_security_group_id = oci_core_network_security_group.server.id
  direction                 = "INGRESS"
  protocol                  = "6"

  tcp_options {
    destination_port_range {
      min = 3001
      max = 3002
    }
  }

  source      = var.vcn_cidr_block
  source_type = "CIDR_BLOCK"
  description = "Client proxy service"
}

# ===================================================================================================
# INSTANCE CONFIGURATION - SERVER CLUSTER
# ===================================================================================================

resource "oci_core_instance_configuration" "server" {
  compartment_id = var.compartment_ocid
  display_name   = "${var.prefix}-server-instance-config"

  instance_details {
    instance_type = "compute"

    launch_details {
      compartment_id = var.compartment_ocid
      display_name   = "${var.prefix}-server"
      shape          = local.cluster_defaults.server.shape

      shape_config {
        ocpus         = local.cluster_defaults.server.ocpus
        memory_in_gbs = local.cluster_defaults.server.memory
      }

      source_details {
        source_type = "image"
        image_id    = var.custom_image_ocid
      }

      create_vnic_details {
        subnet_id      = var.private_subnet_id
        assign_public_ip = false
        nsg_ids        = [oci_core_network_security_group.server.id]
        hostname_label = "${var.prefix}-server"
      }

      metadata = {
        ssh_authorized_keys = var.ssh_public_key
        user_data           = local.instance_user_data.server
      }

      extended_metadata = {
        "cluster-role" = "server"
      }
    }
  }

  defined_tags  = var.defined_tags
  freeform_tags = merge(var.freeform_tags, {
    "Environment" = var.environment
    "ClusterRole" = "server"
  })
}

resource "oci_core_instance_configuration" "api" {
  compartment_id = var.compartment_ocid
  display_name   = "${var.prefix}-api-instance-config"

  instance_details {
    instance_type = "compute"

    launch_details {
      compartment_id = var.compartment_ocid
      display_name   = "${var.prefix}-api"
      shape          = local.cluster_defaults.api.shape

      shape_config {
        ocpus         = local.cluster_defaults.api.ocpus
        memory_in_gbs = local.cluster_defaults.api.memory
      }

      source_details {
        source_type = "image"
        image_id    = var.custom_image_ocid
      }

      create_vnic_details {
        subnet_id        = var.private_subnet_id
        assign_public_ip = false
        nsg_ids          = [oci_core_network_security_group.server.id]
        hostname_label   = "${var.prefix}-api"
      }

      metadata = {
        ssh_authorized_keys = var.ssh_public_key
        user_data           = local.instance_user_data.api
      }

      extended_metadata = {
        "cluster-role" = "api"
      }
    }
  }

  defined_tags  = var.defined_tags
  freeform_tags = merge(var.freeform_tags, {
    "Environment" = var.environment
    "ClusterRole" = "api"
  })
}

resource "oci_core_instance_configuration" "client" {
  compartment_id = var.compartment_ocid
  display_name   = "${var.prefix}-client-instance-config"

  instance_details {
    instance_type = "compute"

    launch_details {
      compartment_id = var.compartment_ocid
      display_name   = "${var.prefix}-client"
      shape          = local.cluster_defaults.client.shape

      shape_config {
        ocpus         = local.cluster_defaults.client.ocpus
        memory_in_gbs = local.cluster_defaults.client.memory
      }

      source_details {
        source_type = "image"
        image_id    = var.custom_image_ocid
      }

      create_vnic_details {
        subnet_id        = var.private_subnet_id
        assign_public_ip = false
        nsg_ids          = [oci_core_network_security_group.server.id]
        hostname_label   = "${var.prefix}-client"
      }

      metadata = {
        ssh_authorized_keys = var.ssh_public_key
        user_data           = local.instance_user_data.client
      }

      extended_metadata = {
        "cluster-role" = "client"
      }
    }
  }

  defined_tags  = var.defined_tags
  freeform_tags = merge(var.freeform_tags, {
    "Environment" = var.environment
    "ClusterRole" = "client"
  })
}

# ===================================================================================================
# INSTANCE POOL - SERVER CLUSTER
# ===================================================================================================

resource "oci_core_instance_pool" "server" {
  compartment_id            = var.compartment_ocid
  display_name              = "${var.prefix}-server-pool"
  instance_configuration_id = oci_core_instance_configuration.server.id
  size                      = local.cluster_defaults.server.size

  dynamic "placement_configurations" {
    for_each = local.availability_domains
    content {
      availability_domain = placement_configurations.value
      primary_subnet_id   = var.private_subnet_id
    }
  }

  defined_tags  = var.defined_tags
  freeform_tags = merge(var.freeform_tags, {
    "Environment" = var.environment
    "ClusterRole" = "server"
  })
}

resource "oci_core_instance_pool" "api" {
  compartment_id            = var.compartment_ocid
  display_name              = "${var.prefix}-api-pool"
  instance_configuration_id = oci_core_instance_configuration.api.id
  size                      = local.cluster_defaults.api.size

  dynamic "placement_configurations" {
    for_each = local.availability_domains
    content {
      availability_domain = placement_configurations.value
      primary_subnet_id   = var.private_subnet_id
    }
  }

  defined_tags  = var.defined_tags
  freeform_tags = merge(var.freeform_tags, {
    "Environment" = var.environment
    "ClusterRole" = "api"
  })
}

resource "oci_core_instance_pool" "client" {
  compartment_id            = var.compartment_ocid
  display_name              = "${var.prefix}-client-pool"
  instance_configuration_id = oci_core_instance_configuration.client.id
  size                      = local.cluster_defaults.client.size

  dynamic "placement_configurations" {
    for_each = local.availability_domains
    content {
      availability_domain = placement_configurations.value
      primary_subnet_id   = var.private_subnet_id
    }
  }

  defined_tags  = var.defined_tags
  freeform_tags = merge(var.freeform_tags, {
    "Environment" = var.environment
    "ClusterRole" = "client"
  })
}


