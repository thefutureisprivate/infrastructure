provider "scaleway" {
  # SCW_ACCESS_KEY and SCW_SECRET_KEY are injected from SOPS.
}

resource "scaleway_object_bucket" "state" {
  name          = var.state_bucket_name
  project_id    = var.scaleway_project_id
  region        = var.scaleway_region
  force_destroy = false
  tags = {
    managed-by = "opentofu-bootstrap"
    purpose    = "encrypted-opentofu-state"
  }

  versioning {
    enabled = true
  }

  lifecycle_rule {
    id      = "state-history"
    prefix  = "infrastructure/"
    enabled = true

    abort_incomplete_multipart_upload_days = 7

    noncurrent_version_expiration {
      noncurrent_days = 400
    }
  }

  lifecycle {
    prevent_destroy = true
  }
}
