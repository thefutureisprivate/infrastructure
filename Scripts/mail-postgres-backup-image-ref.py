#!/usr/bin/env python3
"""Derive the immutable controller-built PostgreSQL backup image reference."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
from pathlib import Path

import yaml


REPO_ROOT = Path(__file__).resolve().parents[1]
DEFAULT_COMPOSE_FILE = REPO_ROOT / "Ansible/compose.yaml"
DEFAULT_CONTAINERFILE = REPO_ROOT / "Ansible/quadlets/mail-postgres.Containerfile"
IMAGE_PATTERN = re.compile(
    r"^docker[.]io/library/postgres:[A-Za-z0-9._-]+@sha256:[0-9a-f]{64}$"
)


def fail(message: str) -> None:
    raise SystemExit(message)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--json", action="store_true", help="emit all build identity fields"
    )
    args = parser.parse_args()

    compose_file = Path(
        os.environ.get("MAIL_IMAGE_LOCK_FILE", DEFAULT_COMPOSE_FILE)
    )
    containerfile = Path(
        os.environ.get("MAIL_POSTGRES_CONTAINERFILE", DEFAULT_CONTAINERFILE)
    )
    try:
        compose = yaml.safe_load(compose_file.read_text(encoding="utf-8"))
        base_image = compose["services"]["postgres"]["image"]
        containerfile_bytes = containerfile.read_bytes()
    except (OSError, UnicodeError, KeyError, TypeError, yaml.YAMLError) as error:
        fail(f"Unable to read the PostgreSQL backup image inputs: {error}")

    if not isinstance(base_image, str) or not IMAGE_PATTERN.fullmatch(base_image):
        fail(f"PostgreSQL base image must be an exact Docker Hub digest: {base_image}")

    digest = hashlib.sha256(
        base_image.encode("utf-8") + b"\0" + containerfile_bytes
    ).hexdigest()
    image = f"localhost/mail-postgres-backup:{digest}"
    if args.json:
        print(
            json.dumps(
                {
                    "base_image": base_image,
                    "image": image,
                    "source_hash": digest,
                },
                separators=(",", ":"),
                sort_keys=True,
            )
        )
    else:
        print(image)


if __name__ == "__main__":
    main()
