locals {
  stalwart_acme_account_uri = "https://acme-v02.api.letsencrypt.org/acme/acct/${var.stalwart_acme_account_id}"

  # These existing records are intentionally outside Stalwart's ownership.
  # Mail records at the zone apex and service-discovery names remain with
  # Stalwart so DKIM rotation and mail-policy changes do not require OpenTofu.
  imported_zone_rrsets = {
    apex_https = {
      subname = "@"
      type    = "HTTPS"
      ttl     = 86400
      rdata   = ["1 . alpn=h2"]
    }
    www_https = {
      subname = "www"
      type    = "HTTPS"
      ttl     = 86400
      rdata   = ["1 . alpn=h2"]
    }
    www_mx = {
      subname = "www"
      type    = "MX"
      ttl     = 86400
      rdata   = ["0 ."]
    }
    www_txt = {
      subname = "www"
      type    = "TXT"
      ttl     = 3600
      rdata   = ["\"v=spf1 -all\""]
    }
  }
}

# The apex denies certificate issuance by default. A more-specific policy on
# the mail host is the only exception, so compromise of Stalwart's ACME account
# and exact DNS challenge permission cannot authorize unrelated zone names.
resource "desec_rrset" "stalwart_caa" {
  domain  = local.desec_zone_name
  subname = "@"
  type    = "CAA"
  ttl     = 3600
  rdata = [
    "0 issue \";\"",
    "0 issuewild \";\"",
    "0 iodef \"mailto:contact@${local.desec_zone_name}\"",
  ]
}

resource "desec_rrset" "stalwart_mail_caa" {
  domain  = local.desec_zone_name
  subname = local.mail_subname
  type    = "CAA"
  ttl     = 3600
  rdata = [
    "128 issue \"letsencrypt.org; accounturi=${local.stalwart_acme_account_uri}; validationmethods=dns-01\"",
    "0 issuewild \";\"",
    "0 iodef \"mailto:contact@${local.desec_zone_name}\"",
  ]
}

# Preserve the state address of the previously imported broad apex CAA RRset
# and update it in place instead of attempting a duplicate create/delete pair.
moved {
  from = desec_rrset.imported_zone["apex_caa"]
  to   = desec_rrset.stalwart_caa
}

import {
  to = desec_rrset.stalwart_caa
  identity = {
    domain  = var.desec_domain
    subname = "@"
    type    = "CAA"
  }
}

resource "desec_rrset" "imported_zone" {
  for_each = local.imported_zone_rrsets

  domain  = local.desec_zone_name
  subname = each.value.subname
  type    = each.value.type
  ttl     = each.value.ttl
  rdata   = each.value.rdata
}

# Declarative imports adopt the live RRsets on the first apply. Keeping these
# blocks is safe: an RRset already in state is not imported again.
import {
  for_each = local.imported_zone_rrsets

  to = desec_rrset.imported_zone[each.key]
  identity = {
    domain  = var.desec_domain
    subname = each.value.subname
    type    = each.value.type
  }
}
