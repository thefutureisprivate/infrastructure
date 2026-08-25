"""Reconcile a rootful Podman secret without placing its value in command text."""

from __future__ import annotations

import hashlib
import re
import shlex
from pathlib import PurePosixPath
from typing import Any

from ansible.errors import AnsibleActionFail
from ansible.plugins.action import ActionBase


_NAME = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_.-]{0,126}$")
_SERVICE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_.@-]*\.service$")
_PATH = re.compile(r"^/[A-Za-z0-9_./@+-]+$")


def _absolute_path(value: Any, label: str, *, directory: bool = False) -> str:
    if not isinstance(value, str) or not _PATH.fullmatch(value):
        raise AnsibleActionFail(f"{label} must use safe absolute-path syntax")
    path = PurePosixPath(value)
    if value == "/" or ".." in path.parts or "." in path.parts:
        raise AnsibleActionFail(f"{label} must not be root or contain traversal")
    if directory:
        if value.endswith("/"):
            raise AnsibleActionFail(f"{label} must not end in a slash")
    elif value.endswith(("/", "/.", "/..")):
        raise AnsibleActionFail(f"{label} must name an executable")
    return value


def build_reconcile_command(
    *,
    name: str,
    desired_hash: str,
    state_directory: str,
    podman_binary: str,
    systemctl_binary: str,
    services: list[str],
) -> str:
    """Build the non-secret remote shell command used by the action."""
    if not isinstance(name, str) or not _NAME.fullmatch(name):
        raise AnsibleActionFail("name has invalid Podman secret syntax")
    if not re.fullmatch(r"[0-9a-f]{64}", desired_hash):
        raise AnsibleActionFail("desired_hash must be a SHA-256 digest")
    state_directory = _absolute_path(
        state_directory, "state_directory", directory=True
    )
    podman_binary = _absolute_path(podman_binary, "podman_binary")
    systemctl_binary = _absolute_path(systemctl_binary, "systemctl_binary")
    if not isinstance(services, list) or any(
        not isinstance(service, str) or not _SERVICE.fullmatch(service)
        for service in services
    ):
        raise AnsibleActionFail("services must contain valid systemd service names")

    stop_commands = "\n".join(
        f'if "$systemctl_bin" is-active --quiet {shlex.quote(service)}; then\n'
        f'  "$systemctl_bin" stop {shlex.quote(service)}\n'
        "fi"
        for service in services
    )
    command = f"""set -eu
umask 077
podman_bin={shlex.quote(podman_binary)}
systemctl_bin={shlex.quote(systemctl_binary)}
secret_name={shlex.quote(name)}
state_file={shlex.quote(f"{state_directory}/{name}.sha256")}
desired_hash={shlex.quote(desired_hash)}

if "$podman_bin" secret exists "$secret_name"; then
  if [ ! -f "$state_file" ] || [ -L "$state_file" ]; then
    printf 'Podman secret %s exists without safe managed state.\n' "$secret_name" >&2
    exit 1
  fi
  if [ "$(cat "$state_file")" = "$desired_hash" ]; then
    if [ "$(stat -c '%a:%u:%g' "$state_file")" != "600:0:0" ]; then
      chmod 0600 "$state_file"
      chown root:root "$state_file"
      printf '%s\n' CHANGED
    fi
    exit 0
  fi
fi

{stop_commands}

if "$podman_bin" secret exists "$secret_name"; then
  "$podman_bin" secret rm "$secret_name"
fi
"$podman_bin" secret create "$secret_name" -

temporary="$(mktemp "${{state_file}}.XXXXXX")"
trap 'rm -f "$temporary"' EXIT HUP INT TERM
printf '%s\n' "$desired_hash" >"$temporary"
chmod 0600 "$temporary"
chown root:root "$temporary"
mv -f "$temporary" "$state_file"
trap - EXIT HUP INT TERM
printf '%s\n' CHANGED
"""
    return command.rstrip()


class ActionModule(ActionBase):
    """Send secret bytes over SSH standard input, never as a module argument."""

    TRANSFERS_FILES = False

    def run(
        self, tmp: str | None = None, task_vars: dict[str, Any] | None = None
    ) -> dict[str, Any]:
        del tmp
        result = super().run(task_vars=task_vars)
        args = self._task.args
        value = args.get("value")
        if not isinstance(value, str):
            raise AnsibleActionFail("value must be a string")

        command = build_reconcile_command(
            name=args.get("name"),
            desired_hash=hashlib.sha256(value.encode("utf-8")).hexdigest(),
            state_directory=args.get("state_directory"),
            podman_binary=args.get("podman_binary"),
            systemctl_binary=args.get("systemctl_binary"),
            services=args.get("services", []),
        )
        execution = self._low_level_execute_command(
            command,
            sudoable=True,
            in_data=value.encode("utf-8"),
        )
        result.update(execution)
        result["changed"] = "CHANGED" in execution.get("stdout", "").splitlines()
        if execution.get("rc", 1) != 0:
            result["failed"] = True
            result["msg"] = "Podman secret reconciliation failed"
        result["_ansible_no_log"] = True
        return result
