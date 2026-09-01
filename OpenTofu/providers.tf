provider "hcloud" {
  # The provider reads HCLOUD_TOKEN from the environment. Keeping credentials
  # out of variables prevents them from being serialized into plan files.
}

provider "desec" {
  # The provider reads DESEC_API_TOKEN from the environment. Its default request
  # serialization protects deSEC's per-domain API rate limits.
}

provider "minio" {
  # The dedicated Hetzner backup project's S3 credentials are supplied as
  # MINIO_USER and MINIO_PASSWORD and synchronized to the mail host.
  minio_server        = "${var.mail_backup_hetzner_location}.your-objectstorage.com"
  minio_region        = var.mail_backup_hetzner_location
  minio_ssl           = true
  minio_insecure      = false
  skip_bucket_tagging = true
  s3_compat_mode      = true
}

provider "b2" {
  # B2_APPLICATION_KEY_ID and B2_APPLICATION_KEY are operator-side account
  # credentials. A bucket-scoped, non-deleting runtime key is generated below.
}

provider "scaleway" {
  # SCW_ACCESS_KEY and SCW_SECRET_KEY remain operator-side. Resources declare
  # their project explicitly so the runtime application can stay isolated.
}
