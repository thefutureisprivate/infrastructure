output "servers" {
  description = "Addresses and identifiers for every FCOS node."
  value = {
    for key, server in hcloud_server.fcos : key => {
      id              = server.id
      name            = server.name
      ipv4            = server.ipv4_address
      ipv6            = server.ipv6_address
      status          = server.status
      bootstrap_image = server.image
    }
  }
}

output "fcos_install_targets" {
  description = "Non-secret server identities consumed by the guarded direct-rescue installer."
  value = {
    for key, server in hcloud_server.fcos : key => {
      id           = server.id
      name         = server.name
      address      = var.nodes[key].ipv4 ? server.ipv4_address : server.ipv6_address
      api_address  = var.nodes[key].ipv4 ? server.ipv4_address : server.ipv6_network
      fqdn         = local.desec_subnames[key] == "@" ? local.desec_zone_name : "${local.desec_subnames[key]}.${local.desec_zone_name}"
      architecture = "x86_64"
    }
  }
}

output "rescue_ssh_key_id" {
  description = "Hetzner SSH-key ID injected into the temporary Rescue System."
  value       = hcloud_ssh_key.operator.id
}

output "ansible_inventory" {
  description = "YAML inventory consumed by Scripts/render-inventory.sh."
  value = templatefile("${path.module}/templates/ansible-inventory.yml.tftpl", {
    mail_node = {
      key             = var.mail_server_node_key
      name            = hcloud_server.fcos[var.mail_server_node_key].name
      connection_host = local.mail_fqdn
    }
    mail_hostname = local.mail_fqdn
    mail_backup = {
      enabled           = local.mail_backup_runtime_enabled
      age_recipient     = var.mail_backup_age_recipient
      hetzner_bucket    = var.mail_backup_hetzner_bucket
      hetzner_endpoint  = local.mail_backup_hetzner_endpoint
      hetzner_region    = var.mail_backup_hetzner_location
      b2_bucket         = var.mail_backup_b2_bucket
      b2_endpoint       = var.mail_backup_b2_endpoint
      b2_region         = var.mail_backup_b2_region
      scaleway_bucket   = var.mail_backup_scaleway_bucket
      scaleway_endpoint = local.mail_backup_scaleway_endpoint
      scaleway_region   = var.mail_backup_scaleway_region
    }
    non_mail_nodes = {
      for key, server in hcloud_server.fcos : key => {
        name            = server.name
        connection_host = local.desec_subnames[key] == "@" ? local.desec_zone_name : "${local.desec_subnames[key]}.${local.desec_zone_name}"
      } if key != var.mail_server_node_key
    }
  })
}

output "mail_backup_storage" {
  description = "Non-secret three-provider backup topology consumed by deployment and recovery procedures."
  value = {
    storage_enabled = var.mail_backup_storage_enabled
    runtime_enabled = local.mail_backup_runtime_enabled
    hetzner = {
      bucket            = var.mail_backup_hetzner_bucket
      endpoint          = local.mail_backup_hetzner_endpoint
      region            = var.mail_backup_hetzner_location
      pgbackrest_prefix = "stalwart/pgbackrest/"
      signed_prefix     = "stalwart/signed-logical/"
    }
    backblaze = {
      bucket            = var.mail_backup_b2_bucket
      endpoint          = var.mail_backup_b2_endpoint
      region            = var.mail_backup_b2_region
      pgbackrest_prefix = "stalwart/pgbackrest/"
      signed_prefix     = "stalwart/signed-logical/"
    }
    scaleway = {
      bucket         = var.mail_backup_scaleway_bucket
      endpoint       = local.mail_backup_scaleway_endpoint
      region         = var.mail_backup_scaleway_region
      prefix         = "logical/"
      retention_days = var.mail_backup_cold_retention_days
    }
  }
}

output "mail_backup_runtime_credentials" {
  description = "Generated runtime credentials synchronized directly into SOPS; never print this output."
  sensitive   = true
  value = local.mail_backup_runtime_enabled ? {
    b2_pgbackrest_key_id = b2_application_key.mail_backup_pgbackrest_runtime[0].application_key_id
    b2_pgbackrest_key    = b2_application_key.mail_backup_pgbackrest_runtime[0].application_key
    b2_archive_key_id    = b2_application_key.mail_backup_signed_runtime[0].application_key_id
    b2_archive_key       = b2_application_key.mail_backup_signed_runtime[0].application_key
    scaleway_access_key  = scaleway_iam_api_key.mail_backup_cold_runtime[0].access_key
    scaleway_secret_key  = scaleway_iam_api_key.mail_backup_cold_runtime[0].secret_key
  } : null
}

output "dns_records" {
  description = "deSEC names created for the FCOS nodes."
  value = {
    for key, server in hcloud_server.fcos : key => {
      fqdn = local.desec_subnames[key] == "@" ? local.desec_zone_name : "${local.desec_subnames[key]}.${local.desec_zone_name}"
      a    = var.nodes[key].ipv4 ? server.ipv4_address : null
      aaaa = var.nodes[key].ipv6 ? server.ipv6_address : null
    }
  }
}

output "desec_dnssec_ds_records" {
  description = "DS records published at the registrar for the existing deSEC zone."
  value = flatten([
    for key in data.desec_domain.fcos.keys : key.ds if key.managed
  ])
}

output "mail_dns" {
  description = "Mail identity used by Stalwart-managed mail records and Hetzner reverse DNS."
  value = {
    hostname = local.mail_fqdn
    domain   = local.desec_zone_name
  }
}

output "stalwart_desec_api_token" {
  description = "Generated, tightly scoped deSEC API token for Stalwart."
  value       = desec_token.stalwart.token
  sensitive   = true
}

output "stalwart_desec_token_scope" {
  description = "Non-secret summary of the generated Stalwart deSEC token's write boundary."
  value = {
    domain = local.desec_zone_name
    records = [
      for key in sort(keys(local.stalwart_desec_record_policies)) : {
        subname = local.stalwart_desec_record_policies[key].subname
        type    = local.stalwart_desec_record_policies[key].type
      }
    ]
    allowed_subnets = sort(local.stalwart_desec_allowed_subnets)
  }
}
