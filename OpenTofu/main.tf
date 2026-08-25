locals {
  common_labels = merge({
    "managed-by" = "opentofu"
    "os"         = "fcos"
    "project"    = var.project_name
  }, var.resource_labels)

  operator_ssh_public_key_path = var.ssh_public_key_file == null ? abspath("${path.root}/../Butane/files/operator.pub") : abspath(var.ssh_public_key_file)
}

resource "hcloud_ssh_key" "operator" {
  name       = "${var.project_name}-operator"
  public_key = trimspace(file(local.operator_ssh_public_key_path))
  labels     = local.common_labels
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
  image       = var.bootstrap_image
  server_type = coalesce(each.value.server_type, var.default_server_type)
  location    = coalesce(each.value.location, var.default_location)
  ssh_keys    = [hcloud_ssh_key.operator.id]

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
    "fcos-installation" = "pending"
    "role"              = each.key == var.mail_server_node_key ? "mail-server" : "fcos-host"
  })

  lifecycle {
    # Scripts/install-fcos.sh changes only this marker after a verified first
    # boot. The remaining labels stay fully managed by OpenTofu.
    ignore_changes = [labels["fcos-installation"]]
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

check "direct_install_architecture" {
  assert {
    condition = alltrue([
      for node in values(var.nodes) :
      !startswith(lower(coalesce(node.server_type, var.default_server_type)), "cax")
    ])
    error_message = "Direct rescue installation currently supports x86_64 server types only; CAX is ARM64."
  }
}
