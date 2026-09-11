SHELL := bash
.SHELLFLAGS := -eu -o pipefail -c
.DEFAULT_GOAL := help

COMPOSE := docker compose
BACKUP_DIR := backups

.PHONY: help up up-full down logs psql psql-docs psql-test db-reset backup setup setup-workspace check smoke

help: ## Show available targets
	@grep -E '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-16s\033[0m %s\n", $$1, $$2}'

up: ## Start PostgreSQL only and print connection URLs
	@scripts/dev-up.sh

up-full: ## Start PostgreSQL, backend, docs and all frontends (builds from ../sk8-*)
	@scripts/dev-up.sh --full

down: ## Stop all containers, keep the database volume
	@scripts/dev-down.sh

logs: ## Follow logs of all running containers
	$(COMPOSE) --profile full logs -f

psql: ## Open psql on sk8_backend
	$(COMPOSE) exec postgres psql -U sk8 -d sk8_backend

psql-docs: ## Open psql on sk8_docs
	$(COMPOSE) exec postgres psql -U sk8 -d sk8_docs

psql-test: ## Open psql on sk8_backend_test
	$(COMPOSE) exec postgres psql -U sk8 -d sk8_backend_test

db-reset: ## Delete the database volume and start fresh (asks for confirmation)
	@scripts/dev-down.sh --volumes
	@scripts/dev-up.sh

backup: ## Dump sk8_backend and sk8_docs into backups/ (pg_dump custom format)
	@mkdir -p $(BACKUP_DIR)
	@stamp=$$(date +%Y%m%d-%H%M%S); \
	for db in sk8_backend sk8_docs; do \
	  $(COMPOSE) exec -T postgres pg_dump -U sk8 -Fc "$$db" > "$(BACKUP_DIR)/$$db-$$stamp.dump"; \
	  echo "written $(BACKUP_DIR)/$$db-$$stamp.dump"; \
	done

setup: ## Activate git hooks, create .env and check local tooling
	@scripts/setup.sh

setup-workspace: ## Clone missing sk8-* repositories and activate their hooks
	@scripts/setup-workspace.sh

check: ## Run the same validations as CI (compose config, bash -n, shellcheck)
	@scripts/check.sh

smoke: ## Run scripts/railway-smoke.sh against SK8_*_URL (defaults: local compose)
	@scripts/railway-smoke.sh
