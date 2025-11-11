locals {
  create_configuration = var.config_id == null
}

resource "oci_psql_configuration" "this" {
  count          = local.create_configuration ? 1 : 0
  compartment_id = var.compartment_id
  db_version     = var.db_version
  display_name   = var.display_name != null ? "${var.display_name}-config" : "postgresql-config"
  shape          = var.shape

  db_configuration_overrides {
    items {
      config_key             = "effective_io_concurrency"
      overriden_config_value = var.effective_io_concurrency
    }
  }

  description                 = "PostgreSQL configuration for ${var.display_name != null ? var.display_name : "postgresql"}"
  instance_memory_size_in_gbs = tostring(var.instance_memory_gbs)
  instance_ocpu_count         = tostring(var.instance_ocpu_count)
}

resource "oci_psql_db_system" "this" {
  compartment_id = var.compartment_id

  credentials {
    password_details {
      password_type  = "PLAIN_TEXT"
      password       = var.db_password
    }
    username = var.db_username
  }

  db_version   = var.db_version
  display_name = coalesce(var.display_name, "postgresql-db")

  network_details {
    subnet_id                   = var.subnet_id
    nsg_ids                     = var.nsg_ids
    is_reader_endpoint_enabled  = var.enable_reader_endpoint
  }

  shape = var.db_system_shape

  storage_details {
    is_regionally_durable = var.is_regionally_durable
    system_type           = "OCI_OPTIMIZED_STORAGE"
    iops                  = var.iops
    availability_domain   = var.storage_availability_domain
  }

  instance_count              = var.instance_count
  instance_memory_size_in_gbs = var.instance_memory_gbs
  instance_ocpu_count         = var.instance_ocpu_count

  config_id = local.create_configuration ? oci_psql_configuration.this[0].id : var.config_id

  freeform_tags = var.freeform_tags
  defined_tags  = var.defined_tags
}


