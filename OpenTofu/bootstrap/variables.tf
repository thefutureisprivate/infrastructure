variable "state_bucket_name" {
  description = "Globally unique Scaleway bucket used only for encrypted OpenTofu state and lock files."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$", var.state_bucket_name))
    error_message = "state_bucket_name must be a valid lowercase S3 bucket name."
  }
}

variable "scaleway_project_id" {
  description = "Dedicated Scaleway project that owns the remote-state bucket."
  type        = string

  validation {
    condition     = can(regex("^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$", var.scaleway_project_id))
    error_message = "scaleway_project_id must be a lowercase UUID."
  }
}

variable "scaleway_region" {
  description = "Paris region used for the encrypted OpenTofu state bucket."
  type        = string
  default     = "fr-par"

  validation {
    condition     = var.scaleway_region == "fr-par"
    error_message = "scaleway_region must be fr-par."
  }
}
