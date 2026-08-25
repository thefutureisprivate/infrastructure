SHELL := /usr/bin/env bash

TOFU ?= tofu
ANSIBLE_PLAYBOOK ?= ansible-playbook
SSH_PUBLIC_KEY_FILE ?= Butane/files/operator.pub
IGNITION_FILE ?= build/fcos.ign
TF_DIR ?= OpenTofu
ANSIBLE_DIR ?= Ansible
TF_VARS ?= terraform.tfvars
SOPS_INFRASTRUCTURE_FILE ?= SOPS/infrastructure.sops.yaml
SOPS_MAIL_FILE ?= SOPS/mail.sops.yaml

.DEFAULT_GOAL := help

.PHONY: help sops-infrastructure-init sops-infrastructure-edit sops-mail-init sops-mail-edit sops-mail-sync-desec ignition image tofu-fmt tofu-init tofu-validate plan apply inventory deploy-bootstrap deploy stalwart-webui-bootstrap stalwart-harden stalwart-audit check clean

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
	@TOFU="$(TOFU)" TF_DIR="$(TF_DIR)" SOPS_MAIL_FILE="$(SOPS_MAIL_FILE)" \
		bash SOPS/sync-stalwart-desec-token.sh

image: ## Upload the current FCOS Hetzner image as a labeled snapshot (billable)
	@SOPS_SECRETS_FILE="$(SOPS_INFRASTRUCTURE_FILE)" bash SOPS/exec-env.sh \
		--allow HCLOUD_TOKEN -- ./Scripts/upload-fcos-image.sh

tofu-fmt: ## Format OpenTofu configuration
	@$(TOFU) -chdir="$(TF_DIR)" fmt -recursive

tofu-init: ## Initialize OpenTofu providers and backend
	@$(TOFU) -chdir="$(TF_DIR)" init

tofu-validate: ignition ## Validate OpenTofu configuration
	@$(TOFU) -chdir="$(TF_DIR)" validate

plan: ignition ## Build Ignition and create an OpenTofu plan
	@SOPS_SECRETS_FILE="$(SOPS_INFRASTRUCTURE_FILE)" bash SOPS/exec-env.sh \
		--allow HCLOUD_TOKEN DESEC_API_TOKEN -- \
		$(TOFU) -chdir="$(TF_DIR)" plan -var-file="$(TF_VARS)" -out=main.tfplan

apply: ## Apply the previously created main.tfplan
	@SOPS_SECRETS_FILE="$(SOPS_INFRASTRUCTURE_FILE)" bash SOPS/exec-env.sh \
		--allow HCLOUD_TOKEN DESEC_API_TOKEN -- \
		$(TOFU) -chdir="$(TF_DIR)" apply main.tfplan
	@$(MAKE) sops-mail-sync-desec

inventory: ## Generate Ansible inventory from OpenTofu outputs
	@./Scripts/render-inventory.sh

deploy-bootstrap: ## Reconcile mail Quadlets with loopback-only Stalwart bootstrap HTTP
	@SOPS_SECRETS_FILE="$(SOPS_MAIL_FILE)" bash SOPS/exec-env.sh \
		--allow MAIL_POSTGRES_PASSWORD STALWART_DESEC_API_TOKEN -- \
		env ANSIBLE_CONFIG="$(ANSIBLE_DIR)/ansible.cfg" \
		$(ANSIBLE_PLAYBOOK) -i "$(ANSIBLE_DIR)/inventory/hosts.yml" "$(ANSIBLE_DIR)/playbooks/quadlets.yml" \
		--extra-vars '{"mail_stalwart_bootstrap_listener": true}'

deploy: ## Reconcile the mail Quadlets on mail-group FCOS nodes
	@SOPS_SECRETS_FILE="$(SOPS_MAIL_FILE)" bash SOPS/exec-env.sh \
		--allow MAIL_POSTGRES_PASSWORD STALWART_DESEC_API_TOKEN -- \
		env ANSIBLE_CONFIG="$(ANSIBLE_DIR)/ansible.cfg" \
		$(ANSIBLE_PLAYBOOK) -i "$(ANSIBLE_DIR)/inventory/hosts.yml" "$(ANSIBLE_DIR)/playbooks/quadlets.yml"

stalwart-webui-bootstrap: ## Replace the bootstrap Web UI with the verified local bundle
	@./Scripts/stalwart-webui-bootstrap.sh

stalwart-harden: ## Idempotently apply the production Stalwart hardening plan
	@SOPS_SECRETS_FILE="$(SOPS_MAIL_FILE)" bash SOPS/exec-env.sh \
		--allow STALWART_CONFIG_API_TOKEN -- ./Scripts/stalwart-hardening.sh apply

stalwart-audit: ## Audit Stalwart configuration, security headers, and implicit TLS
	@SOPS_SECRETS_FILE="$(SOPS_MAIL_FILE)" bash SOPS/exec-env.sh \
		--allow STALWART_CONFIG_API_TOKEN -- ./Scripts/stalwart-hardening.sh audit

check: ## Run all locally available static checks
	@./Scripts/check.sh

clean: ## Remove generated, reproducible build artifacts
	@./Scripts/clean.sh
