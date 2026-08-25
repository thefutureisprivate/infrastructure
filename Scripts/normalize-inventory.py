#!/usr/bin/env python3

import json
import re
import sys
from pathlib import Path

try:
    import yaml
except ModuleNotFoundError:
    raise SystemExit("PyYAML is required (it is installed with Ansible Core).")


def fail(message: str) -> None:
    raise SystemExit(f"Invalid generated Ansible inventory: {message}")


def mapping(value: object, path: str) -> dict:
    if not isinstance(value, dict):
        fail(f"{path} must be a mapping")
    return value


def require_keys(value: dict, expected: set[str], path: str) -> None:
    if set(value) != expected:
        fail(
            f"{path} must contain exactly: {', '.join(sorted(expected))}"
        )


if len(sys.argv) != 3:
    raise SystemExit(f"Usage: {sys.argv[0]} <input.yml> <output.yml>")

input_path = Path(sys.argv[1])
output_path = Path(sys.argv[2])

try:
    inventory = yaml.safe_load(input_path.read_text(encoding="utf-8"))
except (OSError, UnicodeError, yaml.YAMLError) as error:
    fail(f"cannot read YAML: {error}")

root = mapping(inventory, "root")
all_group = mapping(root.get("all"), "all")
all_children = mapping(all_group.get("children"), "all.children")
fcos_group = mapping(all_children.get("fcos"), "all.children.fcos")
fcos_children = mapping(
    fcos_group.get("children"), "all.children.fcos.children"
)
mail_group = mapping(fcos_children.get("mail"), "all.children.fcos.children.mail")
mail_hosts = mapping(
    mail_group.get("hosts"), "all.children.fcos.children.mail.hosts"
)
fcos_hosts = mapping(fcos_group.get("hosts", {}), "all.children.fcos.hosts")

require_keys(root, {"all"}, "root")
require_keys(all_group, {"children", "vars"}, "all")
require_keys(all_children, {"fcos"}, "all.children")
require_keys(
    fcos_group,
    {"children", "hosts"} if "hosts" in fcos_group else {"children"},
    "all.children.fcos",
)
require_keys(fcos_children, {"mail"}, "all.children.fcos.children")
require_keys(mail_group, {"hosts"}, "all.children.fcos.children.mail")

if not mail_hosts:
    fail("mail group must contain at least one host")

for hostname, mail_variables_value in mail_hosts.items():
    if not isinstance(hostname, str) or not re.fullmatch(
        r"[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?", hostname
    ):
        fail(f"unsafe host name {hostname!r}")
    mail_variables = mapping(
        mail_variables_value, f"all.children.fcos.children.mail.hosts.{hostname}"
    )
    fcos_variables = mapping(
        fcos_hosts.pop(hostname, {}), f"all.children.fcos.hosts.{hostname}"
    )
    conflicts = sorted(
        key
        for key in fcos_variables.keys() & mail_variables.keys()
        if fcos_variables[key] != mail_variables[key]
    )
    if conflicts:
        fail(f"conflicting variables for {hostname}: {', '.join(conflicts)}")
    mail_hosts[hostname] = {**fcos_variables, **mail_variables}

for hostname, variables_value in {**fcos_hosts, **mail_hosts}.items():
    variables = mapping(variables_value, f"host {hostname}")
    for required_variable in ("ansible_host", "node_key"):
        if not isinstance(variables.get(required_variable), str) or not variables[
            required_variable
        ]:
            fail(f"host {hostname} is missing {required_variable}")

    allowed_variables = {"ansible_host", "node_key"}
    if hostname in mail_hosts:
        allowed_variables.add("mail_hostname")
        if not isinstance(variables.get("mail_hostname"), str) or not variables[
            "mail_hostname"
        ]:
            fail(f"mail host {hostname} is missing mail_hostname")
    unexpected_variables = sorted(variables.keys() - allowed_variables)
    if unexpected_variables:
        fail(
            f"host {hostname} has unsupported variables: "
            f"{', '.join(unexpected_variables)}"
        )

all_variables = mapping(all_group.get("vars"), "all.vars")
if set(all_variables) != {"ansible_user"} or not isinstance(
    all_variables.get("ansible_user"), str
):
    fail("all.vars must contain only a string ansible_user")


def quoted(value: object, path: str) -> str:
    if not isinstance(value, str) or not value:
        fail(f"{path} must be a non-empty string")
    return json.dumps(value, ensure_ascii=True)


lines = [
    "---",
    "all:",
    "  children:",
    "    fcos:",
    "      children:",
    "        mail:",
    "          hosts:",
]
for hostname in sorted(mail_hosts):
    variables = mail_hosts[hostname]
    lines.extend(
        [
            f"            {hostname}:",
            "              ansible_host: "
            + quoted(variables["ansible_host"], f"{hostname}.ansible_host"),
            "              node_key: "
            + quoted(variables["node_key"], f"{hostname}.node_key"),
            "              mail_hostname: "
            + quoted(variables["mail_hostname"], f"{hostname}.mail_hostname"),
        ]
    )
if fcos_hosts:
    lines.append("      hosts:")
    for hostname in sorted(fcos_hosts):
        variables = fcos_hosts[hostname]
        lines.extend(
            [
                f"        {hostname}:",
                "          ansible_host: "
                + quoted(variables["ansible_host"], f"{hostname}.ansible_host"),
                "          node_key: "
                + quoted(variables["node_key"], f"{hostname}.node_key"),
            ]
        )
lines.extend(
    [
        "  vars:",
        "    ansible_user: "
        + quoted(all_variables["ansible_user"], "all.vars.ansible_user"),
        "",
    ]
)

try:
    output_path.write_text("\n".join(lines), encoding="utf-8")
except (OSError, UnicodeError) as error:
    fail(f"cannot write YAML: {error}")
