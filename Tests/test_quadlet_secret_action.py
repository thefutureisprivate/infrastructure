#!/usr/bin/env python3
"""Focused regression tests for stdin-only Podman secret transport."""

from __future__ import annotations

import importlib.util
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
PLUGIN = REPO_ROOT / "Ansible/plugins/action/quadlet_secret.py"
spec = importlib.util.spec_from_file_location("quadlet_secret", PLUGIN)
assert spec is not None and spec.loader is not None
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

sentinel = "never-place-this-secret-in-command-text"
command = module.build_reconcile_command(
    name="mail-password",
    desired_hash="a" * 64,
    state_directory="/var/lib/quadlet-secrets",
    podman_binary="/usr/bin/podman",
    systemctl_binary="/usr/bin/systemctl",
    services=["mail-stalwart.service"],
)
assert sentinel not in command
assert "base64" not in command
assert 'secret create "$secret_name" -' in command

source = PLUGIN.read_text(encoding="utf-8")
assert "in_data=value.encode" in source
assert "b64encode" not in source
print("Quadlet secret transport: stdin-only")
