SHELL := /usr/bin/env bash
.DEFAULT_GOAL := help

# Fleet selection — override on the command line, e.g.
#   make rollout TAG=Role=app REGION=eu-west-1 TG_ARN=arn:aws:elasticloadbalancing:...
INSTANCES ?=
TAG       ?=
REGION    ?=
TG_ARN    ?=
SIZE_MIB  ?= 8192
SWAPPINESS ?= 10
SOAK      ?= 600

SCRIPTS := $(wildcard scripts/*.sh) $(wildcard tests/*.sh) tests/mockbin/aws

TARGET_ARGS = $(if $(INSTANCES),--instances $(INSTANCES)) $(if $(TAG),--tag $(TAG)) \
              $(if $(REGION),--region $(REGION)) $(if $(TG_ARN),--target-group-arn $(TG_ARN)) \
              --swap-size-mib $(SIZE_MIB) --swappiness $(SWAPPINESS) --soak-seconds $(SOAK)

.PHONY: help
help: ## Show available targets
	@grep -E '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) | \
	  awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-12s\033[0m %s\n", $$1, $$2}'

.PHONY: lint
lint: ## Run shellcheck, yamllint and markdownlint
	shellcheck -x $(SCRIPTS)
	yamllint -c .yamllint.yml .
	markdownlint --config .markdownlint.json '**/*.md'
	./scripts/build-ssm-document.sh --check

.PHONY: test
test: ## Run the rollout tests against a mock AWS CLI
	./tests/test-rolling-rollout.sh

.PHONY: ssm-doc
ssm-doc: ## Regenerate ssm/configure-swap.yml from scripts/configure-swap.sh
	./scripts/build-ssm-document.sh

.PHONY: preflight
preflight: ## Dry run: preflight checks only, no changes
	./scripts/rolling-rollout.sh $(TARGET_ARGS) --dry-run

.PHONY: rollout
rollout: ## Rolling rollout, one instance at a time
	./scripts/rolling-rollout.sh $(TARGET_ARGS) --action configure

.PHONY: verify
verify: ## Verify swap configuration on every target
	./scripts/rolling-rollout.sh $(TARGET_ARGS) --action verify --soak-seconds 0

.PHONY: rollback
rollback: ## Roll back swap configuration, one instance at a time
	./scripts/rolling-rollout.sh $(TARGET_ARGS) --action rollback
