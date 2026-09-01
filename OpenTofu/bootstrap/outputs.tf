output "backend" {
  description = "Non-secret values to copy into ../backend.hcl."
  value = {
    bucket   = scaleway_object_bucket.state.name
    endpoint = "https://s3.${var.scaleway_region}.scw.cloud"
    region   = var.scaleway_region
  }
}
