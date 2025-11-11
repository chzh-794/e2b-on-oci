data "oci_objectstorage_namespace" "this" {
  compartment_id = var.compartment_id
}

locals {
  namespace = data.oci_objectstorage_namespace.this.namespace
}

resource "oci_objectstorage_bucket" "this" {
  compartment_id = var.compartment_id
  name           = var.bucket_name
  namespace      = local.namespace

  access_type  = var.access_type
  auto_tiering = var.auto_tiering

  defined_tags  = var.defined_tags
  freeform_tags = var.freeform_tags
}

resource "oci_objectstorage_object_lifecycle_policy" "this" {
  count     = var.create_lifecycle_policy ? 1 : 0
  bucket    = oci_objectstorage_bucket.this.name
  namespace = local.namespace

  rules {
    name        = "prune-old-files"
    action      = "DELETE"
    is_enabled  = true
    time_amount = var.lifecycle_time_amount
    time_unit   = var.lifecycle_time_unit
  }
}

resource "oci_objectstorage_replication_policy" "this" {
  count     = var.create_replication_policy ? 1 : 0
  bucket    = oci_objectstorage_bucket.this.name
  namespace = local.namespace

  name                    = "bucket-replication"
  destination_bucket_name = var.replication_destination_bucket_name
  destination_region_name = var.replication_destination_region
}


