terraform {
  required_version = ">= 1.12.0, < 2.0.0"

  # Backend arguments are intentionally supplied from the ignored backend.hcl
  # file. Credentials remain environment-only and are never serialized here.
  backend "s3" {}

  required_providers {
    hcloud = {
      source  = "hetznercloud/hcloud"
      version = "~> 1.68"
    }
    desec = {
      source  = "timofurrer/desec"
      version = "~> 0.6"
    }
    minio = {
      source  = "aminueza/minio"
      version = "~> 3.40"
    }
    b2 = {
      source  = "Backblaze/b2"
      version = "~> 0.13"
    }
    scaleway = {
      source  = "scaleway/scaleway"
      version = "~> 2.80"
    }
    time = {
      source  = "hashicorp/time"
      version = "~> 0.14"
    }
  }
}
