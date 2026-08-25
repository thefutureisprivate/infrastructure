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
  description = "Existing deSEC zone whose host records and scoped Stalwart token are managed by this stack."
  type        = string
  nullable    = false

  validation {
    condition = (
      length(var.desec_domain) <= 253 &&
      length(split(".", var.desec_domain)) >= 2 &&
      alltrue([
        for label in split(".", var.desec_domain) :
        length(label) <= 63 && can(regex("^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?$", label))
      ])
    )
    error_message = "desec_domain must be a valid Punycode DNS zone name without a trailing dot."
  }
}

variable "stalwart_dkim_selectors" {
  description = "Exact active Stalwart DKIM selector labels authorized in deSEC. Leave empty only for initial bootstrap, then authorize selectors before automatic publication."
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

variable "desec_ttl" {
  description = "TTL in seconds for managed node address records."
  type        = number
  default     = 300

  validation {
    condition     = var.desec_ttl >= 60 && var.desec_ttl <= 86400
    error_message = "desec_ttl must be between 60 and 86400 seconds."
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
