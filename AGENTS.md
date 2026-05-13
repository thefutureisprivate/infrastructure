# AGENTS.md

## Project Overview

This repository manages personal infrastructure with Ansible.

- `inventory.yml` defines `servers`, `pve`, `pbs`, `vm`, and `desktops`.
- `pbs.yml` configures Proxmox Backup Server hosts.
- `pve.yml` configures Proxmox Virtual Environment hosts.
- `roles/hardening` manages SSH, chrony, coredumps, fwupd, NetworkManager, sysctl, udev, and kernel hardening.
- `roles/pbs` contains Debian/PBS compatibility tasks that must run before the hardening role on PBS hosts.

## YAML Style

Follow the "A simple subset of yaml" guidance from <https://ruuda.nl/2023/the-yaml-document-from-hell> for every `.yml` and `.yaml` file in this repository.

- Run `yamllint .` before committing YAML changes. The repository `.yamllint` file is the canonical enforcement for the subset that yamllint can check.
- Quote every string value, including hostnames, usernames, task names, inventory names, group names when written as values, and module arguments.
- Ordinary mapping keys such as `name`, `hosts`, `tasks`, and Ansible module names do not need quotes. Quote keys only when they would otherwise be ambiguous YAML.
- Prefer single quotes for strings. Use double quotes only when escape sequences or interpolation make them clearer.
- Leave booleans unquoted only when they are real booleans, and write them only as `true` or `false`.
- Leave numbers unquoted only when they are real numbers.
- Avoid YAML aliases, anchors, merge keys, tags, flow-style maps/lists, implicit document typing tricks, and multi-document streams.
- Use ordinary block-style mappings and lists with two-space indentation.
- Do not use `yes`, `no`, `on`, `off`, `y`, or `n` as booleans.
- When a value should remain a string even if it looks like a boolean, number, date, or null value, quote it.

## Ansible Conventions

- Install Ansible collection requirements with `ansible-galaxy collection install -r requirements.yml` when the local environment is missing collections.
- Run `ansible-lint pbs.yml pve.yml roles/hardening roles/pbs` before committing Ansible changes. The repository `.ansible-lint` file enforces the production profile in strict mode.
- Always use FQCN module names such as `ansible.builtin.copy`.
- Every task must have a `name`.
- Every `command` or `shell` task must define `changed_when`, and add `failed_when` when the command can fail idempotently.
- Prefer `argv` over a single shell-like string for `ansible.builtin.command` when arguments are complex.
- Keep tasks idempotent and route service restarts through handlers where practical.
- Keep distro-specific compatibility in the target role when possible. For PBS/PVE/Debian compatibility, prefer `roles/pbs` or `roles/pve` over adding Debian branches to generic hardening tasks.
- Preserve source and license references in copied config files.

## Secrets

- Use SOPS with Age for secrets.
- Store encrypted Ansible variable files as `*.sops.yml` or `*.sops.yaml` under `group_vars`, `host_vars`, or `secrets`.
- Keep the Age private identity outside the repository and provide it with `SOPS_AGE_KEY_FILE`.
- Never commit unencrypted `secrets.yml`, decrypted scratch files, or Age private keys.

## Validation

Run the relevant checks after changes:

- `ansible-galaxy collection install -r requirements.yml`
- `yamllint .`
- `ansible-lint pbs.yml pve.yml roles/hardening roles/pbs`
- `ansible-playbook -i inventory.yml --syntax-check pbs.yml`
- `ansible-playbook -i inventory.yml --syntax-check pve.yml`
