locals {
  mail_backup_hetzner_endpoint = "${var.mail_backup_hetzner_location}.your-objectstorage.com"
  mail_backup_runtime_enabled  = var.mail_backup_storage_enabled && var.mail_backup_enabled
  mail_backup_scaleway_endpoint = (
    "https://s3.${var.mail_backup_scaleway_region}.scw.cloud"
  )
}

resource "minio_s3_bucket" "mail_backup_hot" {
  count = var.mail_backup_storage_enabled ? 1 : 0

  bucket        = var.mail_backup_hetzner_bucket
  acl           = "private"
  force_destroy = false

  lifecycle {
    prevent_destroy = true
  }
}

resource "minio_s3_bucket_versioning" "mail_backup_hot" {
  count = var.mail_backup_storage_enabled ? 1 : 0

  bucket = minio_s3_bucket.mail_backup_hot[0].bucket

  versioning_configuration {
    status = "Enabled"
  }
}

resource "b2_bucket" "mail_backup_hot" {
  count = var.mail_backup_storage_enabled ? 1 : 0

  bucket_name = var.mail_backup_b2_bucket
  bucket_type = "allPrivate"
  bucket_info = {
    managed_by = "opentofu"
    purpose    = "encrypted-pgbackrest"
  }

  lifecycle_rules {
    file_name_prefix                                       = "stalwart/"
    days_from_starting_to_canceling_unfinished_large_files = 7
  }

  lifecycle {
    prevent_destroy = true
  }
}

resource "b2_application_key" "mail_backup_pgbackrest_runtime" {
  count = local.mail_backup_runtime_enabled ? 1 : 0

  key_name    = "${var.project_name}-pgbackrest-runtime"
  bucket_ids  = [b2_bucket.mail_backup_hot[0].bucket_id]
  name_prefix = "stalwart/pgbackrest/"
  capabilities = [
    "listBuckets",
    "listFiles",
    "readFiles",
    "writeFiles",
  ]
}

resource "b2_application_key" "mail_backup_signed_runtime" {
  count = local.mail_backup_runtime_enabled ? 1 : 0

  key_name    = "${var.project_name}-signed-backup-runtime"
  bucket_ids  = [b2_bucket.mail_backup_hot[0].bucket_id]
  name_prefix = "stalwart/signed-logical/"
  capabilities = [
    "listBuckets",
    "writeFiles",
  ]
}

resource "scaleway_object_bucket" "mail_backup_cold" {
  count = var.mail_backup_storage_enabled ? 1 : 0

  name                = var.mail_backup_scaleway_bucket
  project_id          = var.mail_backup_scaleway_project_id
  region              = var.mail_backup_scaleway_region
  force_destroy       = false
  object_lock_enabled = true
  tags = {
    managed-by = "opentofu"
    purpose    = "encrypted-logical-mail-backup"
  }

  versioning {
    enabled = true
  }

  lifecycle_rule {
    id      = "logical-glacier-retention"
    prefix  = "logical/"
    enabled = true

    abort_incomplete_multipart_upload_days = 7

    transition {
      # Scaleway rejects Glacier lifecycle transitions earlier than 90 days.
      days          = 90
      storage_class = "GLACIER"
    }

    expiration {
      days = var.mail_backup_cold_retention_days
    }
  }

  lifecycle {
    prevent_destroy = true
  }
}

resource "scaleway_object_bucket_lock_configuration" "mail_backup_cold" {
  count = var.mail_backup_storage_enabled ? 1 : 0

  bucket     = scaleway_object_bucket.mail_backup_cold[0].name
  project_id = var.mail_backup_scaleway_project_id

  rule {
    default_retention {
      mode = "COMPLIANCE"
      days = var.mail_backup_cold_retention_days
    }
  }
}

data "scaleway_account_project" "mail_backup_cold" {
  count = local.mail_backup_runtime_enabled ? 1 : 0

  project_id = var.mail_backup_scaleway_project_id
}

resource "scaleway_iam_application" "mail_backup_cold_runtime" {
  count = local.mail_backup_runtime_enabled ? 1 : 0

  name            = "${var.project_name}-cold-backup-runtime"
  description     = "Write-only age-encrypted Stalwart logical backups"
  organization_id = data.scaleway_account_project.mail_backup_cold[0].organization_id
  tags            = ["managed-by-opentofu", "mail-backup"]
}

resource "scaleway_iam_policy" "mail_backup_cold_runtime" {
  count = local.mail_backup_runtime_enabled ? 1 : 0

  name            = "${var.project_name}-cold-backup-write"
  description     = "Create objects only in the dedicated cold-backup project"
  organization_id = data.scaleway_account_project.mail_backup_cold[0].organization_id
  application_id  = scaleway_iam_application.mail_backup_cold_runtime[0].id

  rule {
    project_ids          = [var.mail_backup_scaleway_project_id]
    permission_set_names = ["ObjectStorageObjectsWrite"]
  }
}

resource "time_rotating" "mail_backup_scaleway_api_key" {
  count = local.mail_backup_runtime_enabled ? 1 : 0

  rotation_years = 1
}

resource "scaleway_iam_api_key" "mail_backup_cold_runtime" {
  count = local.mail_backup_runtime_enabled ? 1 : 0

  application_id     = scaleway_iam_application.mail_backup_cold_runtime[0].id
  default_project_id = var.mail_backup_scaleway_project_id
  description        = "Write-only key for age-encrypted Stalwart logical backups"
  expires_at         = time_rotating.mail_backup_scaleway_api_key[0].rotation_rfc3339

  depends_on = [scaleway_iam_policy.mail_backup_cold_runtime]

  lifecycle {
    create_before_destroy = true
  }
}

check "mail_backup_inputs" {
  assert {
    condition = !var.mail_backup_storage_enabled || alltrue([
      var.mail_backup_hetzner_bucket != "",
      var.mail_backup_b2_bucket != "",
      var.mail_backup_scaleway_bucket != "",
      var.mail_backup_scaleway_project_id != "",
    ])
    error_message = "Enabling mail backup storage requires all three bucket identities and the dedicated Scaleway project."
  }

  assert {
    condition = !var.mail_backup_storage_enabled || length(distinct([
      lower(var.mail_backup_hetzner_bucket),
      lower(var.mail_backup_b2_bucket),
      lower(var.mail_backup_scaleway_bucket),
    ])) == 3
    error_message = "Each backup provider must use a distinct bucket name."
  }

}
