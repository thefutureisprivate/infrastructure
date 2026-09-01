SHELL := /usr/bin/env bash

TOFU ?= tofu
ANSIBLE_PLAYBOOK ?= ansible-playbook
SSH_PUBLIC_KEY_FILE ?= Butane/files/operator.pub
IGNITION_FILE ?= build/fcos.ign
TF_DIR ?= OpenTofu
ANSIBLE_DIR ?= Ansible
TF_VARS ?= terraform.tfvars
STALWART_AUTHORITY_VARS ?= stalwart-authority.tfvars.json
STALWART_BOOTSTRAP_SECRET_NAME ?=
STALWART_BOOTSTRAP_TLS ?= false
SOPS_INFRASTRUCTURE_FILE ?= SOPS/infrastructure.sops.yaml
SOPS_MAIL_FILE ?= SOPS/mail.sops.yaml
TF_VAR_ARGS = -var-file="$(TF_VARS)" -var-file="$(STALWART_AUTHORITY_VARS)"

.DEFAULT_GOAL := help

.PHONY: help sops-infrastructure-init sops-infrastructure-edit sops-mail-init sops-mail-edit sops-mail-sync-desec sops-mail-sync-backup sops-mail-generate-backup-signing-key sops-mail-rotate-backup-signing-key ignition install tofu-fmt tofu-backend-bootstrap tofu-state-snapshot tofu-state-restore tofu-init tofu-upgrade tofu-validate tofu-output plan apply inventory base-deploy mail-postgres-image deploy-bootstrap deploy stalwart-bootstrap stalwart-harden stalwart-audit silverblue-check silverblue-apply check clean

help: ## Show available targets
	@awk 'BEGIN {FS = ":.*## "; printf "Usage: make <target>\n\nTargets:\n"} /^[a-zA-Z0-9_-]+:.*## / {printf "  %-16s %s\n", $$1, $$2}' $(MAKEFILE_LIST)

ignition: ## Compile Butane into build/fcos.ign with the configured operator key
	@SSH_PUBLIC_KEY_FILE="$(SSH_PUBLIC_KEY_FILE)" ./Scripts/render-ignition.sh "$(IGNITION_FILE)"

sops-infrastructure-init: ## Encrypt the OpenTofu provider-token template
	@bash SOPS/init.sh "$(SOPS_INFRASTRUCTURE_FILE)" SOPS/infrastructure.example.yaml

sops-infrastructure-edit: ## Edit OpenTofu provider tokens through SOPS
	@sops "$(SOPS_INFRASTRUCTURE_FILE)"

sops-mail-init: ## Encrypt the Ansible mail-secret template
	@bash SOPS/init.sh "$(SOPS_MAIL_FILE)" SOPS/mail.example.yaml

sops-mail-edit: ## Edit Ansible mail secrets through SOPS
	@sops "$(SOPS_MAIL_FILE)"

sops-mail-sync-desec: ## Store the generated Stalwart deSEC token in encrypted mail secrets
	@SOPS_SECRETS_FILE="$(SOPS_INFRASTRUCTURE_FILE)" bash SOPS/exec-env.sh \
		--allow SCW_ACCESS_KEY SCW_SECRET_KEY TOFU_STATE_PASSPHRASE -- \
		env TOFU="$(CURDIR)/Scripts/tofu.sh" TOFU_BINARY="$(TOFU)" TF_DIR="$(TF_DIR)" SOPS_MAIL_FILE="$(SOPS_MAIL_FILE)" \
		bash SOPS/sync-stalwart-desec-token.sh

sops-mail-sync-backup: ## Store Hetzner, generated B2, and Scaleway runtime keys in mail secrets
	@SOPS_SECRETS_FILE="$(SOPS_INFRASTRUCTURE_FILE)" bash SOPS/exec-env.sh \
		--allow SCW_ACCESS_KEY SCW_SECRET_KEY TOFU_STATE_PASSPHRASE \
		--optional MINIO_USER MINIO_PASSWORD -- \
		env TOFU="$(CURDIR)/Scripts/tofu.sh" TOFU_BINARY="$(TOFU)" TF_DIR="$(TF_DIR)" SOPS_MAIL_FILE="$(SOPS_MAIL_FILE)" \
		bash SOPS/sync-backup-credentials.sh

sops-mail-generate-backup-signing-key: ## Generate and encrypt the backup Ed25519 signing pair
	@SOPS_MAIL_FILE="$(SOPS_MAIL_FILE)" ./Scripts/generate-backup-signing-key.sh

sops-mail-rotate-backup-signing-key: ## Rotate the backup signing key and retain its public verification history
	@SOPS_MAIL_FILE="$(SOPS_MAIL_FILE)" ./Scripts/generate-backup-signing-key.sh --rotate

install: ignition ## Install FCOS directly onto pending Hetzner servers through Rescue
	@SOPS_SECRETS_FILE="$(SOPS_INFRASTRUCTURE_FILE)" bash SOPS/exec-env.sh \
		--allow HCLOUD_TOKEN SCW_ACCESS_KEY SCW_SECRET_KEY TOFU_STATE_PASSPHRASE -- \
		env TOFU="$(CURDIR)/Scripts/tofu.sh" TOFU_BINARY="$(TOFU)" TF_DIR="$(TF_DIR)" IGNITION_FILE="$(IGNITION_FILE)" \
		./Scripts/install-fcos.sh

tofu-fmt: ## Format OpenTofu configuration
	@$(TOFU) -chdir="$(TF_DIR)" fmt -recursive

tofu-backend-bootstrap: ## Create the versioned Scaleway state bucket from encrypted local bootstrap state
	@SOPS_SECRETS_FILE="$(SOPS_INFRASTRUCTURE_FILE)" bash SOPS/exec-env.sh \
		--allow SCW_ACCESS_KEY SCW_SECRET_KEY TOFU_STATE_PASSPHRASE -- \
		env TOFU_BINARY="$(TOFU)" ./Scripts/tofu.sh -chdir="$(TF_DIR)/bootstrap" init
	@SOPS_SECRETS_FILE="$(SOPS_INFRASTRUCTURE_FILE)" bash SOPS/exec-env.sh \
		--allow SCW_ACCESS_KEY SCW_SECRET_KEY TOFU_STATE_PASSPHRASE -- \
		env TOFU_BINARY="$(TOFU)" ./Scripts/tofu.sh -chdir="$(TF_DIR)/bootstrap" apply -var-file=terraform.tfvars

tofu-state-snapshot: ## Save a SOPS-encrypted local recovery copy of remote state
	@SOPS_SECRETS_FILE="$(SOPS_INFRASTRUCTURE_FILE)" bash SOPS/exec-env.sh \
		--allow SCW_ACCESS_KEY SCW_SECRET_KEY TOFU_STATE_PASSPHRASE -- \
		env TOFU_BINARY="$(TOFU)" TF_DIR="$(TF_DIR)" ./Scripts/snapshot-tofu-state.sh

tofu-state-restore: ## Restore an encrypted local snapshot after confirmed remote-state loss
	@test -n "$(TOFU_STATE_SNAPSHOT)" || { printf 'Set TOFU_STATE_SNAPSHOT to an exact file under %s/state-snapshots.\n' "$(TF_DIR)" >&2; exit 2; }
	@SOPS_SECRETS_FILE="$(SOPS_INFRASTRUCTURE_FILE)" bash SOPS/exec-env.sh \
		--allow SCW_ACCESS_KEY SCW_SECRET_KEY TOFU_STATE_PASSPHRASE -- \
		env TOFU_BINARY="$(TOFU)" TF_DIR="$(TF_DIR)" \
		./Scripts/restore-tofu-state-snapshot.sh "$(TOFU_STATE_SNAPSHOT)"

tofu-init: ## Initialize OpenTofu providers and backend
	@SOPS_SECRETS_FILE="$(SOPS_INFRASTRUCTURE_FILE)" bash SOPS/exec-env.sh \
		--allow SCW_ACCESS_KEY SCW_SECRET_KEY TOFU_STATE_PASSPHRASE -- \
		env TOFU_BINARY="$(TOFU)" ./Scripts/tofu.sh -chdir="$(TF_DIR)" init -backend-config=backend.hcl

tofu-upgrade: ## Intentionally upgrade OpenTofu providers and refresh their lock hashes
	@SOPS_SECRETS_FILE="$(SOPS_INFRASTRUCTURE_FILE)" bash SOPS/exec-env.sh \
		--allow SCW_ACCESS_KEY SCW_SECRET_KEY TOFU_STATE_PASSPHRASE -- \
		env TOFU_BINARY="$(TOFU)" ./Scripts/tofu.sh -chdir="$(TF_DIR)" init -upgrade -backend-config=backend.hcl

tofu-validate: ## Validate OpenTofu configuration
	@SOPS_SECRETS_FILE="$(SOPS_INFRASTRUCTURE_FILE)" bash SOPS/exec-env.sh \
		--allow TOFU_STATE_PASSPHRASE -- env TOFU_BINARY="$(TOFU)" ./Scripts/tofu.sh -chdir="$(TF_DIR)" validate

tofu-output: ## Show non-sensitive OpenTofu outputs through the encrypted backend wrapper
	@SOPS_SECRETS_FILE="$(SOPS_INFRASTRUCTURE_FILE)" bash SOPS/exec-env.sh \
		--allow SCW_ACCESS_KEY SCW_SECRET_KEY TOFU_STATE_PASSPHRASE -- \
		env TOFU_BINARY="$(TOFU)" ./Scripts/tofu.sh -chdir="$(TF_DIR)" output

plan: ## Create a saved OpenTofu plan
	@SOPS_SECRETS_FILE="$(SOPS_INFRASTRUCTURE_FILE)" bash SOPS/exec-env.sh \
		--allow HCLOUD_TOKEN DESEC_API_TOKEN SCW_ACCESS_KEY SCW_SECRET_KEY TOFU_STATE_PASSPHRASE \
		--optional MINIO_USER MINIO_PASSWORD B2_APPLICATION_KEY_ID B2_APPLICATION_KEY -- \
		env TOFU_BINARY="$(TOFU)" ./Scripts/tofu.sh -chdir="$(TF_DIR)" plan $(TF_VAR_ARGS) -out=main.tfplan

apply: ## Apply the previously created main.tfplan
	@SOPS_SECRETS_FILE="$(SOPS_INFRASTRUCTURE_FILE)" bash SOPS/exec-env.sh \
		--allow HCLOUD_TOKEN DESEC_API_TOKEN SCW_ACCESS_KEY SCW_SECRET_KEY TOFU_STATE_PASSPHRASE \
		--optional MINIO_USER MINIO_PASSWORD B2_APPLICATION_KEY_ID B2_APPLICATION_KEY -- \
		env TOFU_BINARY="$(TOFU)" ./Scripts/tofu.sh -chdir="$(TF_DIR)" apply main.tfplan
	@$(MAKE) tofu-state-snapshot
	@$(MAKE) sops-mail-sync-desec
	@$(MAKE) sops-mail-sync-backup
	@rm -f -- "$(TF_DIR)/main.tfplan"

inventory: ## Generate Ansible inventory from OpenTofu outputs
	@SOPS_SECRETS_FILE="$(SOPS_INFRASTRUCTURE_FILE)" bash SOPS/exec-env.sh \
		--allow SCW_ACCESS_KEY SCW_SECRET_KEY TOFU_STATE_PASSPHRASE -- \
		env TOFU="$(CURDIR)/Scripts/tofu.sh" TOFU_BINARY="$(TOFU)" ./Scripts/render-inventory.sh

base-deploy: ## Reconcile the shared FCOS host baseline
	@env ANSIBLE_CONFIG="$(ANSIBLE_DIR)/ansible.cfg" \
		$(ANSIBLE_PLAYBOOK) -i "$(ANSIBLE_DIR)/inventory/hosts.yml" "$(ANSIBLE_DIR)/playbooks/base.yml"

mail-postgres-image: ## Build the pinned backup image locally and transfer a verified OCI archive
	@./Scripts/deploy-mail-postgres-image.sh

deploy-bootstrap: base-deploy mail-postgres-image ## Reconcile mail Quadlets with temporary Stalwart recovery access
	@[[ "$(STALWART_BOOTSTRAP_SECRET_NAME)" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]{0,126}$$ ]] || { \
		printf 'STALWART_BOOTSTRAP_SECRET_NAME must name the temporary server-side Podman secret.\n' >&2; \
		exit 2; \
	}
	@[[ "$(STALWART_BOOTSTRAP_TLS)" == true || "$(STALWART_BOOTSTRAP_TLS)" == false ]] || { \
		printf 'STALWART_BOOTSTRAP_TLS must be true or false.\n' >&2; \
		exit 2; \
	}
	@SOPS_SECRETS_FILE="$(SOPS_MAIL_FILE)" bash SOPS/exec-env.sh \
		--allow MAIL_POSTGRES_ADMIN_PASSWORD MAIL_POSTGRES_PASSWORD MAIL_POSTGRES_DUMP_PASSWORD STALWART_DESEC_API_TOKEN \
		--optional PGBACKREST_REPO1_CIPHER_PASS PGBACKREST_REPO2_S3_KEY PGBACKREST_REPO2_S3_KEY_SECRET PGBACKREST_REPO2_CIPHER_PASS MAIL_BACKUP_SCALEWAY_ACCESS_KEY MAIL_BACKUP_SCALEWAY_SECRET_KEY MAIL_BACKUP_HETZNER_ACCESS_KEY MAIL_BACKUP_HETZNER_SECRET_KEY MAIL_BACKUP_B2_ACCESS_KEY MAIL_BACKUP_B2_SECRET_KEY MAIL_BACKUP_SIGNING_PRIVATE_KEY MAIL_BACKUP_SIGNING_PUBLIC_KEY -- \
		env ANSIBLE_CONFIG="$(ANSIBLE_DIR)/ansible.cfg" \
		STALWART_BOOTSTRAP_SECRET_NAME="$(STALWART_BOOTSTRAP_SECRET_NAME)" \
		$(ANSIBLE_PLAYBOOK) -i "$(ANSIBLE_DIR)/inventory/hosts.yml" "$(ANSIBLE_DIR)/playbooks/quadlets.yml" \
		--extra-vars '{"mail_stalwart_bootstrap_listener": true, "mail_stalwart_bootstrap_tls": $(STALWART_BOOTSTRAP_TLS)}'

deploy: base-deploy mail-postgres-image ## Reconcile the mail Quadlets on mail-group FCOS nodes
	@SOPS_SECRETS_FILE="$(SOPS_MAIL_FILE)" bash SOPS/exec-env.sh \
		--allow MAIL_POSTGRES_ADMIN_PASSWORD MAIL_POSTGRES_PASSWORD MAIL_POSTGRES_DUMP_PASSWORD STALWART_DESEC_API_TOKEN \
		--optional PGBACKREST_REPO1_CIPHER_PASS PGBACKREST_REPO2_S3_KEY PGBACKREST_REPO2_S3_KEY_SECRET PGBACKREST_REPO2_CIPHER_PASS MAIL_BACKUP_SCALEWAY_ACCESS_KEY MAIL_BACKUP_SCALEWAY_SECRET_KEY MAIL_BACKUP_HETZNER_ACCESS_KEY MAIL_BACKUP_HETZNER_SECRET_KEY MAIL_BACKUP_B2_ACCESS_KEY MAIL_BACKUP_B2_SECRET_KEY MAIL_BACKUP_SIGNING_PRIVATE_KEY MAIL_BACKUP_SIGNING_PUBLIC_KEY -- \
		env ANSIBLE_CONFIG="$(ANSIBLE_DIR)/ansible.cfg" \
		$(ANSIBLE_PLAYBOOK) -i "$(ANSIBLE_DIR)/inventory/hosts.yml" "$(ANSIBLE_DIR)/playbooks/quadlets.yml"

stalwart-bootstrap: ## Automate Stalwart DNS, DKIM, staged ACME, and production certificate setup
	@TOFU="$(CURDIR)/Scripts/tofu.sh" TOFU_BINARY="$(TOFU)" TF_DIR="$(TF_DIR)" TF_VARS="$(TF_VARS)" \
		STALWART_AUTHORITY_VARS="$(STALWART_AUTHORITY_VARS)" \
		SOPS_INFRASTRUCTURE_FILE="$(SOPS_INFRASTRUCTURE_FILE)" \
		./Scripts/stalwart-bootstrap.sh

stalwart-harden: ## Idempotently apply the production Stalwart hardening plan
	@SOPS_SECRETS_FILE="$(SOPS_MAIL_FILE)" bash SOPS/exec-env.sh \
		--allow STALWART_CONFIG_API_TOKEN -- ./Scripts/stalwart-hardening.sh apply

stalwart-audit: ## Audit Stalwart configuration, security headers, and implicit TLS
	@SOPS_SECRETS_FILE="$(SOPS_MAIL_FILE)" bash SOPS/exec-env.sh \
		--allow STALWART_CONFIG_API_TOKEN -- ./Scripts/stalwart-hardening.sh audit

silverblue-check: ## Preview local Silverblue reconciliation
	@env ANSIBLE_CONFIG="$(ANSIBLE_DIR)/ansible.cfg" \
		$(ANSIBLE_PLAYBOOK) -i "$(ANSIBLE_DIR)/inventory/silverblue.yml" \
		"$(ANSIBLE_DIR)/playbooks/silverblue.yml" --check --diff --ask-become-pass

silverblue-apply: ## Reconcile the local Silverblue workstation
	@env ANSIBLE_CONFIG="$(ANSIBLE_DIR)/ansible.cfg" \
		$(ANSIBLE_PLAYBOOK) -i "$(ANSIBLE_DIR)/inventory/silverblue.yml" \
		"$(ANSIBLE_DIR)/playbooks/silverblue.yml" --diff --ask-become-pass

check: ## Run all locally available static checks
	@./Scripts/check.sh

clean: ## Remove generated, reproducible build artifacts
	@./Scripts/clean.sh
