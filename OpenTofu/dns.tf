locals {
  desec_zone_name = data.desec_domain.fcos.name
  desec_subnames = {
    for key, server in hcloud_server.fcos :
    key => lookup(var.desec_node_subnames, key, server.name)
  }

  desec_ipv4_addresses = {
    for key, server in hcloud_server.fcos : key => server.ipv4_address
    if var.nodes[key].ipv4
  }

  desec_ipv6_addresses = {
    for key, server in hcloud_server.fcos : key => server.ipv6_address
    if var.nodes[key].ipv6
  }

  # deSEC token policies match exact owner names. Keep this list aligned with
  # the reviewed Stalwart v0.16.19 zone output; never replace it with a
  # type-only or wildcard policy.
  stalwart_desec_record_policies = merge({
    apex_mx                   = { subname = "@", type = "MX" }
    apex_spf                  = { subname = "@", type = "TXT" }
    apex_caa                  = { subname = "@", type = "CAA" }
    mail_spf                  = { subname = local.mail_subname, type = "TXT" }
    dmarc                     = { subname = "_dmarc", type = "TXT" }
    tls_reporting             = { subname = "_smtp._tls", type = "TXT" }
    mta_sts_alias             = { subname = "mta-sts", type = "CNAME" }
    mta_sts_policy            = { subname = "_mta-sts", type = "TXT" }
    user_agent_autoconfig     = { subname = "ua-auto-config", type = "CNAME" }
    user_agent_autoconfig_txt = { subname = "_ua-auto-config", type = "TXT" }
    legacy_autoconfig         = { subname = "autoconfig", type = "CNAME" }
    autodiscover              = { subname = "autodiscover", type = "CNAME" }
    jmap_service              = { subname = "_jmap._tcp", type = "SRV" }
    caldav_service            = { subname = "_caldavs._tcp", type = "SRV" }
    carddav_service           = { subname = "_carddavs._tcp", type = "SRV" }
    imaps_service             = { subname = "_imaps._tcp", type = "SRV" }
    submissions_service       = { subname = "_submissions._tcp", type = "SRV" }
    apex_acme_challenge       = { subname = "_acme-challenge", type = "TXT" }
    mail_acme_challenge       = { subname = "_acme-challenge.${local.mail_subname}", type = "TXT" }
    acme_validation_persist   = { subname = "_validation-persist", type = "TXT" }
    }, {
    for selector in var.stalwart_dkim_selectors :
    "dkim_${selector}" => {
      subname = "${selector}._domainkey"
      type    = "TXT"
    }
  })
  stalwart_desec_allowed_subnets = compact([
    try(var.nodes[var.mail_server_node_key].ipv4 ? hcloud_server.fcos[var.mail_server_node_key].ipv4_address : null, null),
    try(var.nodes[var.mail_server_node_key].ipv6 ? hcloud_server.fcos[var.mail_server_node_key].ipv6_address : null, null),
  ])

  mail_subname = try(local.desec_subnames[var.mail_server_node_key], "mail")
  mail_fqdn    = "${local.mail_subname}.${local.desec_zone_name}"
}

data "desec_domain" "fcos" {
  name = var.desec_domain
}

resource "desec_token" "stalwart" {
  name               = "${var.project_name}-stalwart"
  allowed_subnets    = sort(local.stalwart_desec_allowed_subnets)
  auto_policy        = false
  perm_create_domain = false
  perm_delete_domain = false
  perm_manage_tokens = false
}

resource "desec_token_policy" "stalwart_default_deny" {
  token_id   = desec_token.stalwart.id
  perm_write = false
}

resource "desec_token_policy" "stalwart_mail_records" {
  for_each = local.stalwart_desec_record_policies

  token_id   = desec_token.stalwart.id
  domain     = data.desec_domain.fcos.name
  subname    = each.value.subname
  type       = each.value.type
  perm_write = true

  depends_on = [desec_token_policy.stalwart_default_deny]
}

resource "desec_rrset" "node_a" {
  for_each = local.desec_ipv4_addresses

  domain  = local.desec_zone_name
  subname = local.desec_subnames[each.key]
  type    = "A"
  ttl     = var.desec_ttl
  rdata   = [each.value]
}

resource "desec_rrset" "node_aaaa" {
  for_each = local.desec_ipv6_addresses

  domain  = local.desec_zone_name
  subname = local.desec_subnames[each.key]
  type    = "AAAA"
  ttl     = var.desec_ttl
  rdata   = [each.value]
}

resource "hcloud_rdns" "mail_ipv4" {
  count = try(var.nodes[var.mail_server_node_key].ipv4, false) ? 1 : 0

  server_id  = hcloud_server.fcos[var.mail_server_node_key].id
  ip_address = hcloud_server.fcos[var.mail_server_node_key].ipv4_address
  dns_ptr    = local.mail_fqdn

  depends_on = [desec_rrset.node_a]
}

resource "hcloud_rdns" "mail_ipv6" {
  count = try(var.nodes[var.mail_server_node_key].ipv6, false) ? 1 : 0

  server_id  = hcloud_server.fcos[var.mail_server_node_key].id
  ip_address = hcloud_server.fcos[var.mail_server_node_key].ipv6_address
  dns_ptr    = local.mail_fqdn

  depends_on = [desec_rrset.node_aaaa]
}

resource "hcloud_rdns" "node_ipv4" {
  for_each = {
    for key, address in local.desec_ipv4_addresses : key => address
    if key != var.mail_server_node_key
  }

  server_id  = hcloud_server.fcos[each.key].id
  ip_address = each.value
  dns_ptr    = local.desec_subnames[each.key] == "@" ? local.desec_zone_name : "${local.desec_subnames[each.key]}.${local.desec_zone_name}"

  depends_on = [desec_rrset.node_a]
}

resource "hcloud_rdns" "node_ipv6" {
  for_each = {
    for key, address in local.desec_ipv6_addresses : key => address
    if key != var.mail_server_node_key
  }

  server_id  = hcloud_server.fcos[each.key].id
  ip_address = each.value
  dns_ptr    = local.desec_subnames[each.key] == "@" ? local.desec_zone_name : "${local.desec_subnames[each.key]}.${local.desec_zone_name}"

  depends_on = [desec_rrset.node_aaaa]
}

check "desec_configuration" {
  assert {
    condition = alltrue([
      for key in keys(var.desec_node_subnames) : contains(keys(var.nodes), key)
    ])
    error_message = "Every desec_node_subnames key must refer to a key in nodes."
  }

  assert {
    condition     = local.mail_subname != "@"
    error_message = "The mail host needs a non-apex DNS name so its address and reverse-DNS records can match."
  }
}
