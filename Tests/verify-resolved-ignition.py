#!/usr/bin/env python3
"""Verify security-critical properties of the rendered FCOS Ignition."""

from __future__ import annotations

import base64
import gzip
import json
import sys
from pathlib import Path
from urllib.parse import unquote_to_bytes


def fail(message: str) -> None:
    raise SystemExit(f"FCOS Ignition policy: {message}")


def embedded_file(
    config: dict[str, object], wanted_path: str
) -> tuple[dict[str, object], str]:
    storage = config.get("storage")
    if not isinstance(storage, dict):
        fail("storage section is missing")
    files = storage.get("files", [])
    if not isinstance(files, list):
        fail("storage.files is not a list")
    matches = [
        item
        for item in files
        if isinstance(item, dict) and item.get("path") == wanted_path
    ]
    if len(matches) != 1:
        fail(f"expected one {wanted_path} file, found {len(matches)}")

    item = matches[0]
    contents = item.get("contents")
    if not isinstance(contents, dict):
        fail(f"{wanted_path} has no embedded contents")
    source = contents.get("source")
    if not isinstance(source, str) or not source.startswith("data:"):
        fail(f"{wanted_path} does not use an embedded data URL")
    metadata, separator, payload = source.partition(",")
    if not separator:
        fail(f"{wanted_path} has an invalid data URL")
    try:
        raw = (
            base64.b64decode(payload, validate=True)
            if metadata.endswith(";base64")
            else unquote_to_bytes(payload)
        )
        if contents.get("compression") == "gzip":
            raw = gzip.decompress(raw)
        elif contents.get("compression") not in (None, ""):
            fail(f"{wanted_path} uses an unsupported compression type")
        return item, raw.decode("utf-8")
    except (ValueError, OSError, UnicodeDecodeError) as error:
        fail(f"cannot decode {wanted_path}: {error}")


def require_assignments(text: str, wanted: dict[str, list[str]], label: str) -> None:
    actual: dict[str, list[str]] = {}
    for raw_line in text.splitlines():
        line = raw_line.strip()
        if not line or line.startswith(("#", "[")) or "=" not in line:
            continue
        key, value = line.split("=", 1)
        actual.setdefault(key, []).append(value)
    for key, values in wanted.items():
        if actual.get(key) != values:
            fail(f"{label} has {key}={actual.get(key)!r}; expected {values!r}")


def main() -> None:
    ignition_path = Path(sys.argv[1] if len(sys.argv) > 1 else "build/fcos.ign")
    try:
        config = json.loads(ignition_path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        fail(f"cannot read {ignition_path}: {error}")

    storage = config.get("storage")
    links = storage.get("links", []) if isinstance(storage, dict) else []
    resolv_links = [
        item
        for item in links
        if isinstance(item, dict) and item.get("path") == "/etc/resolv.conf"
    ]
    if len(resolv_links) != 1:
        fail(f"expected one /etc/resolv.conf link, found {len(resolv_links)}")
    resolv_link = resolv_links[0]
    if resolv_link.get("target") != "/run/systemd/resolve/stub-resolv.conf":
        fail("/etc/resolv.conf does not target the full systemd-resolved stub")
    if resolv_link.get("hard", False):
        fail("/etc/resolv.conf must be a symbolic link")
    if resolv_link.get("overwrite") is not True:
        fail("/etc/resolv.conf replacement is not explicit")

    _, resolved_text = embedded_file(
        config, "/etc/systemd/resolved.conf.d/60-fcos-encrypted-dns.conf"
    )
    require_assignments(
        resolved_text,
        {
            "DNS": [
                "",
                "1.1.1.1#one.one.one.one 1.0.0.1#one.one.one.one "
                "2606:4700:4700::1111#one.one.one.one "
                "2606:4700:4700::1001#one.one.one.one",
            ],
            "FallbackDNS": [""],
            "Domains": ["", "~."],
            "DNSSEC": ["yes"],
            "DNSOverTLS": ["yes"],
            "DNSStubListener": ["yes"],
            "LLMNR": ["no"],
            "MulticastDNS": ["no"],
        },
        "systemd-resolved drop-in",
    )

    _, network_manager_text = embedded_file(
        config, "/etc/NetworkManager/conf.d/60-fcos-encrypted-dns.conf"
    )
    require_assignments(
        network_manager_text,
        {"dns": ["none"], "systemd-resolved": ["false"]},
        "NetworkManager drop-in",
    )

    zram_item, zram_text = embedded_file(
        config, "/etc/systemd/zram-generator.conf"
    )
    if zram_item.get("mode") != 0o644:
        fail("zram-generator configuration does not use mode 0644")
    for owner_type in ("user", "group"):
        owner = zram_item.get(owner_type)
        if not isinstance(owner, dict) or owner.get("name") != "root":
            fail(f"zram-generator configuration {owner_type} is not root")
    if zram_text != "[zram0]\nzram-size = ram / 2\n":
        fail("zram-generator configuration has unexpected contents")

    systemd = config.get("systemd")
    units = systemd.get("units", []) if isinstance(systemd, dict) else []
    resolved_units = [
        item
        for item in units
        if isinstance(item, dict) and item.get("name") == "systemd-resolved.service"
    ]
    if len(resolved_units) != 1 or resolved_units[0].get("enabled") is not True:
        fail("systemd-resolved.service is not explicitly enabled")

    sudoers_item, sudoers_text = embedded_file(
        config, "/etc/sudoers.d/60-thefutureisprivate"
    )
    if sudoers_item.get("mode") != 0o440:
        fail("operator sudoers drop-in does not use mode 0440")
    for owner_type in ("user", "group"):
        owner = sudoers_item.get(owner_type)
        if not isinstance(owner, dict) or owner.get("name") != "root":
            fail(f"operator sudoers drop-in {owner_type} is not root")
    if sudoers_text != "thefutureisprivate ALL=(root) NOPASSWD: ALL\n":
        fail("operator sudoers drop-in has unexpected contents")

    ipv6_script_item, ipv6_script_text = embedded_file(
        config, "/usr/local/sbin/configure-hetzner-ipv6"
    )
    if ipv6_script_item.get("mode") != 0o755:
        fail("Hetzner IPv6 configurator does not use mode 0755")
    for required_fragment in (
        "http://169.254.169.254/hetzner/v1/metadata/network-config",
        "/sys/class/net/*/address",
        "ipv6.method manual",
        "ipv6.ignore-auto-dns yes",
        'nmcli device reapply "${interface}"',
    ):
        if required_fragment not in ipv6_script_text:
            fail(f"Hetzner IPv6 configurator is missing {required_fragment!r}")

    ipv6_units = [
        item
        for item in units
        if isinstance(item, dict) and item.get("name") == "hetzner-ipv6.service"
    ]
    if len(ipv6_units) != 1 or ipv6_units[0].get("enabled") is not True:
        fail("hetzner-ipv6.service is not explicitly enabled")
    ipv6_unit_contents = ipv6_units[0].get("contents")
    if not isinstance(ipv6_unit_contents, str):
        fail("hetzner-ipv6.service has no unit contents")
    for required_fragment in (
        "ExecStart=/usr/local/sbin/configure-hetzner-ipv6",
        "NoNewPrivileges=yes",
        "ProtectSystem=strict",
        "RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6 AF_NETLINK",
    ):
        if required_fragment not in ipv6_unit_contents:
            fail(f"hetzner-ipv6.service is missing {required_fragment!r}")

    print("FCOS Ignition policy: OK")


if __name__ == "__main__":
    main()
