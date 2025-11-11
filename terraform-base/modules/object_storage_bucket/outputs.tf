output "bucket_id" {
  description = "OCID of the created bucket"
  value       = oci_objectstorage_bucket.this.id
}

output "bucket_name" {
  description = "Name of the created bucket"
  value       = oci_objectstorage_bucket.this.name
}

output "namespace" {
  description = "Namespace hosting the bucket"
  value       = data.oci_objectstorage_namespace.this.namespace
}


