locals {
  common_labels = merge({
    "managed-by" = "opentofu"
    "os"         = "fcos"
    "project"    = var.project_name
  }, var.resource_labels)

  ignition_path = var.ignition_file == null ? abspath("${path.root}/../build/fcos.ign") : abspath(var.ignition_file)
  ignition      = file(local.ignition_path)

  selected_image_id = var.fcos_image_id != null ? var.fcos_image_id : data.hcloud_image.fcos[0].id
}

data "hcloud_image" "fcos" {
  count = var.fcos_image_id == null ? 1 : 0

  with_selector     = var.fcos_image_selector
  with_architecture = var.image_architecture
  most_recent       = true
}

resource "hcloud_firewall" "fcos" {
  name   = "${var.project_name}-fcos-base"
  labels = local.common_labels

  rule {
    direction   = "in"
    protocol    = "tcp"
    port        = "22"
    source_ips  = ["0.0.0.0/0", "::/0"]
    description = "SSH"
  }

  rule {
    direction   = "in"
    protocol    = "icmp"
    source_ips  = ["0.0.0.0/0", "::/0"]
    description = "ICMP for path MTU discovery and diagnostics"
  }
}

resource "hcloud_firewall" "mail" {
  name   = "${var.project_name}-mail"
  labels = merge(local.common_labels, { "role" = "mail-server" })

  dynamic "rule" {
    for_each = var.mail_ingress_rules

    content {
      direction   = "in"
      protocol    = rule.value.protocol
      port        = rule.value.port
      source_ips  = sort(tolist(rule.value.source_ips))
      description = rule.value.description
    }
  }
}

resource "hcloud_placement_group" "fcos" {
  count = var.enable_spread_placement_group && length(var.nodes) > 1 ? 1 : 0

  name   = "${var.project_name}-fcos"
  type   = "spread"
  labels = local.common_labels
}

resource "hcloud_server" "fcos" {
  for_each = var.nodes

  name        = "${var.name_prefix}-${each.key}"
  image       = local.selected_image_id
  server_type = coalesce(each.value.server_type, var.default_server_type)
  location    = coalesce(each.value.location, var.default_location)
  user_data   = local.ignition

  firewall_ids = each.key == var.mail_server_node_key ? [
    hcloud_firewall.fcos.id,
    hcloud_firewall.mail.id,
  ] : [hcloud_firewall.fcos.id]
  placement_group_id = try(hcloud_placement_group.fcos[0].id, null)

  public_net {
    ipv4_enabled = each.value.ipv4
    ipv6_enabled = each.value.ipv6
  }

  backups                  = var.enable_backups
  delete_protection        = var.enable_delete_protection
  rebuild_protection       = var.enable_delete_protection
  shutdown_before_deletion = true

  labels = merge(local.common_labels, each.value.labels, {
    "role" = each.key == var.mail_server_node_key ? "mail-server" : "fcos-host"
  })
}

check "ignition_user_data_limit" {
  assert {
    condition     = length(local.ignition) <= 32768
    error_message = "The compiled Ignition config exceeds Hetzner's 32 KiB user-data limit."
  }
}

check "mail_server_node" {
  assert {
    condition     = contains(keys(var.nodes), var.mail_server_node_key)
    error_message = "mail_server_node_key must refer to a key in nodes."
  }

  assert {
    condition     = try(var.nodes[var.mail_server_node_key].ipv4, false)
    error_message = "The mail-server node must have IPv4 enabled for broad SMTP interoperability."
  }
}
