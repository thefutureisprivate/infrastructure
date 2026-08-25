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
  value = yamlencode({
    all = {
      children = {
        fcos = {
          hosts = {
            for key, server in hcloud_server.fcos : server.name => {
              ansible_host = var.nodes[key].ipv4 ? server.ipv4_address : server.ipv6_address
              node_key     = key
            }
          }
          children = {
            mail = {
              hosts = {
                for key, server in hcloud_server.fcos : server.name => {
                  mail_hostname = local.mail_fqdn
                } if key == var.mail_server_node_key
              }
            }
          }
        }
      }
      vars = {
        ansible_user = "thefutureisprivate"
      }
    }
  })
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
