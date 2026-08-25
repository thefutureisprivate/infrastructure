terraform {
  required_version = ">= 1.12.0, < 2.0.0"

  required_providers {
    hcloud = {
      source  = "hetznercloud/hcloud"
      version = "~> 1.68"
    }
    desec = {
      source  = "timofurrer/desec"
      version = "~> 0.6"
    }
  }
}
