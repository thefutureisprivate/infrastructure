variable "project_name" {
  description = "Lowercase project label used on every managed resource."
  type        = string
  default     = "fcos-infrastructure"

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9-]{0,61}[a-z0-9]$", var.project_name))
    error_message = "project_name must be a lowercase Hetzner-compatible label value between 2 and 63 characters."
  }
}

variable "name_prefix" {
  description = "Prefix used to construct server hostnames."
  type        = string
  default     = "fcos"

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9-]{0,30}$", var.name_prefix))
    error_message = "name_prefix must contain at most 31 lowercase letters, digits, or hyphens."
  }
}

variable "bootstrap_image" {
  description = "Native Hetzner image used only until the final server is overwritten from Rescue."
  type        = string
  default     = "fedora-44"

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9.-]+$", var.bootstrap_image))
    error_message = "bootstrap_image must be a non-empty Hetzner system-image name."
  }
}

variable "ssh_public_key_file" {
  description = "Optional operator public-key path; defaults to ../Butane/files/operator.pub."
  type        = string
  default     = null
}

variable "default_server_type" {
  description = "Default x86_64 Hetzner server type used by the direct Rescue installer."
  type        = string
  default     = "cx23"
}

variable "default_location" {
  description = "Default Hetzner location."
  type        = string
  default     = "nbg1"
}

variable "nodes" {
  description = "FCOS nodes keyed by a short, hostname-safe suffix."
  type = map(object({
    server_type = optional(string)
    location    = optional(string)
    ipv4        = optional(bool, true)
    ipv6        = optional(bool, true)
    labels      = optional(map(string), {})
  }))
  default = {
    "01" = {}
  }

  validation {
    condition = length(var.nodes) > 0 && alltrue([
      for key, node in var.nodes :
      can(regex("^[a-z0-9][a-z0-9-]{0,30}$", key)) && (node.ipv4 || node.ipv6)
    ])
    error_message = "Define at least one node; keys must be hostname-safe and each node needs IPv4 or IPv6."
  }
}

variable "mail_server_node_key" {
  description = "Key in nodes that runs Stalwart and PostgreSQL and receives mail DNS and reverse-DNS records."
  type        = string
  default     = "01"

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9-]{0,30}$", var.mail_server_node_key))
    error_message = "mail_server_node_key must be a hostname-safe nodes key."
  }
}

variable "primary_ip_import_ids" {
  description = "Existing Hetzner Primary IP resource IDs to adopt without replacing their addresses. Leave empty for newly created nodes."
  type = map(object({
    ipv4 = optional(number)
    ipv6 = optional(number)
  }))
  default = {}

  validation {
    condition = alltrue(flatten([
      for addresses in values(var.primary_ip_import_ids) : [
        addresses.ipv4 == null || addresses.ipv4 > 0,
        addresses.ipv6 == null || addresses.ipv6 > 0,
      ]
    ]))
    error_message = "Imported Primary IP IDs must be positive Hetzner resource IDs."
  }
}

variable "mail_ingress_rules" {
  description = "Inbound application rules attached only to the selected mail-server node."
  type = list(object({
    description = string
    protocol    = string
    port        = optional(string)
    source_ips  = set(string)
  }))
  default = []

  validation {
    condition = alltrue([
      for rule in var.mail_ingress_rules :
      contains(["tcp", "udp", "icmp", "esp", "gre"], rule.protocol) &&
      length(rule.source_ips) > 0 &&
      alltrue([for cidr in rule.source_ips : can(cidrhost(cidr, 0))]) &&
      (contains(["tcp", "udp"], rule.protocol) ? rule.port != null : rule.port == null)
    ])
    error_message = "Ingress rules need a supported protocol, valid CIDRs, and ports only for TCP or UDP."
  }
}

variable "resource_labels" {
  description = "Additional labels merged onto managed resources."
  type        = map(string)
  default     = {}
}

variable "enable_spread_placement_group" {
  description = "Place multiple nodes in a Hetzner spread placement group."
  type        = bool
  default     = true
}

variable "enable_backups" {
  description = "Enable billable Hetzner backups for every node."
  type        = bool
  default     = true
}

variable "enable_delete_protection" {
  description = "Enable Hetzner delete and rebuild protection. The provider can still lift it during destroy."
  type        = bool
  default     = true
}

variable "desec_domain" {
  description = "Existing deSEC zone managed by this single-domain stack. Security-report recipients and reviewed mail authority are intentionally bound to thefutureisprivate.dev."
  type        = string
  nullable    = false

  validation {
    condition     = var.desec_domain == "thefutureisprivate.dev"
    error_message = "desec_domain must be thefutureisprivate.dev; this stack's security-report recipients and mail authority are intentionally domain-specific."
  }
}

variable "stalwart_dkim_selectors" {
  description = "Exact reviewed active or retiring Stalwart DKIM selector labels authorized in deSEC. Normal plans load them from stalwart-authority.tfvars.json."
  type        = set(string)
  default     = []

  validation {
    condition = alltrue([
      for selector in var.stalwart_dkim_selectors :
      can(regex("^[A-Za-z0-9][A-Za-z0-9_-]{0,62}$", selector))
    ])
    error_message = "Every stalwart_dkim_selectors entry must be an exact single-label DKIM selector."
  }
}

variable "stalwart_acme_account_uri" {
  description = "Reviewed production ACME account URI. Bootstrap compares Stalwart to this controller-owned value before changing CAA."
  type        = string
  default     = null
  nullable    = true

  validation {
    condition = (
      var.stalwart_acme_account_uri == null ||
      can(regex("^https://acme(-staging)?-v02[.]api[.]letsencrypt[.]org/acme/acct/[0-9]+$", var.stalwart_acme_account_uri))
    )
    error_message = "stalwart_acme_account_uri must be null or an exact Let's Encrypt staging or production ACME account URI."
  }
}

variable "stalwart_staging_acme_account_uri" {
  description = "Reviewed staging ACME account URI used only during an explicitly approved first enrollment."
  type        = string
  default     = null
  nullable    = true

  validation {
    condition = (
      var.stalwart_staging_acme_account_uri == null ||
      can(regex("^https://acme-staging-v02[.]api[.]letsencrypt[.]org/acme/acct/[0-9]+$", var.stalwart_staging_acme_account_uri))
    )
    error_message = "stalwart_staging_acme_account_uri must be null or an exact reviewed Let's Encrypt staging account URI."
  }
}

variable "desec_ttl" {
  description = "TTL in seconds for managed node address records."
  type        = number
  default     = 3600

  validation {
    condition     = var.desec_ttl >= 3600 && var.desec_ttl <= 86400
    error_message = "desec_ttl must be between deSEC's 3600-second minimum and 86400 seconds."
  }
}

variable "desec_node_subnames" {
  description = "Optional node-key to DNS-subname overrides. Defaults to each Hetzner server name. Use @ for the apex."
  type        = map(string)
  default = {
    "01" = "mail"
  }

  validation {
    condition = alltrue([
      for subname in values(var.desec_node_subnames) :
      subname == "@" || can(regex("^[A-Za-z0-9_*-]+(\\.[A-Za-z0-9_*-]+)*$", subname))
    ])
    error_message = "deSEC subnames must be @ or dot-separated DNS labels."
  }
}

variable "mail_backup_storage_enabled" {
  description = "Keep the protected three-provider mail backup storage declared independently of host runtime access and schedules."
  type        = bool
}

variable "mail_backup_enabled" {
  description = "Create runtime backup identities and publish host schedules; requires durable storage and an age recipient."
  type        = bool
  default     = false

  validation {
    condition = !var.mail_backup_enabled || (
      var.mail_backup_storage_enabled && var.mail_backup_age_recipient != ""
    )
    error_message = "mail_backup_enabled requires mail_backup_storage_enabled and mail_backup_age_recipient; disable runtime while leaving storage enabled to pause backups safely."
  }
}

variable "mail_backup_hetzner_bucket" {
  description = "Globally unique Hetzner Object Storage bucket for the first encrypted pgBackRest repository."
  type        = string
  default     = ""

  validation {
    condition     = var.mail_backup_hetzner_bucket == "" || can(regex("^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$", var.mail_backup_hetzner_bucket))
    error_message = "mail_backup_hetzner_bucket must be empty or a valid lowercase S3 bucket name."
  }
}

variable "mail_backup_hetzner_location" {
  description = "Hetzner Object Storage location used for the first hot repository."
  type        = string
  default     = "nbg1"

  validation {
    condition     = contains(["fsn1", "nbg1", "hel1"], var.mail_backup_hetzner_location)
    error_message = "mail_backup_hetzner_location must be fsn1, nbg1, or hel1."
  }
}

variable "mail_backup_b2_bucket" {
  description = "Globally unique Backblaze B2 bucket for the second encrypted pgBackRest repository."
  type        = string
  default     = ""

  validation {
    condition     = var.mail_backup_b2_bucket == "" || can(regex("^[A-Za-z0-9][A-Za-z0-9-]{4,48}[A-Za-z0-9]$", var.mail_backup_b2_bucket))
    error_message = "mail_backup_b2_bucket must be empty or a valid 6-50 character B2 bucket name."
  }
}

variable "mail_backup_b2_region" {
  description = "Backblaze B2 S3 region assigned to the account."
  type        = string
  default     = "eu-central-003"

  validation {
    condition     = can(regex("^[a-z0-9-]+$", var.mail_backup_b2_region))
    error_message = "mail_backup_b2_region must be a lowercase S3 region identifier."
  }
}

variable "mail_backup_b2_endpoint" {
  description = "Backblaze B2 S3 endpoint hostname without a URL scheme."
  type        = string
  default     = "s3.eu-central-003.backblazeb2.com"

  validation {
    condition     = can(regex("^[A-Za-z0-9.-]+[.]backblazeb2[.]com$", var.mail_backup_b2_endpoint))
    error_message = "mail_backup_b2_endpoint must be a Backblaze S3 endpoint hostname without a scheme."
  }
}

variable "mail_backup_scaleway_bucket" {
  description = "Globally unique Scaleway Object Storage bucket for age-encrypted logical archives."
  type        = string
  default     = ""

  validation {
    condition     = var.mail_backup_scaleway_bucket == "" || can(regex("^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$", var.mail_backup_scaleway_bucket))
    error_message = "mail_backup_scaleway_bucket must be empty or a valid lowercase S3 bucket name."
  }
}

variable "mail_backup_scaleway_region" {
  description = "Paris region used for the Scaleway Glacier cold archive."
  type        = string
  default     = "fr-par"

  validation {
    condition     = var.mail_backup_scaleway_region == "fr-par"
    error_message = "mail_backup_scaleway_region must be fr-par."
  }
}

variable "mail_backup_scaleway_project_id" {
  description = "Dedicated Scaleway project containing only the cold backup bucket."
  type        = string
  default     = ""

  validation {
    condition     = var.mail_backup_scaleway_project_id == "" || can(regex("^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$", var.mail_backup_scaleway_project_id))
    error_message = "mail_backup_scaleway_project_id must be empty or a lowercase UUID."
  }
}

variable "mail_backup_age_recipient" {
  description = "Public age recipient used on the mail host; its private identity must exist only in tested offline custody."
  type        = string
  default     = ""

  validation {
    condition     = var.mail_backup_age_recipient == "" || can(regex("^age1[0-9a-z]{40,}$", var.mail_backup_age_recipient))
    error_message = "mail_backup_age_recipient must be empty or a valid native age recipient."
  }
}

variable "mail_backup_cold_retention_days" {
  description = "Immutable retention and eventual expiry for age-encrypted Scaleway archives."
  type        = number
  default     = 400

  validation {
    condition     = var.mail_backup_cold_retention_days >= 90 && var.mail_backup_cold_retention_days <= 3650 && floor(var.mail_backup_cold_retention_days) == var.mail_backup_cold_retention_days
    error_message = "mail_backup_cold_retention_days must be an integer between 90 and 3650."
  }
}
