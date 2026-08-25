locals {
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
