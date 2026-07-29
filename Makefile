SHELL := /bin/bash
MODULES := $(shell find modules -mindepth 1 -maxdepth 1 -type d | sort)
EXAMPLES := $(shell find examples -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort)

.PHONY: help fmt fmt-check validate test tools-test lint docs check clean

help: ## Show this help
	@grep -hE '^[a-z-]+:.*?##' $(MAKEFILE_LIST) | awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-14s\033[0m %s\n", $$1, $$2}'

fmt: ## Reformat all the HCL
	terraform fmt -recursive

fmt-check: ## Check formatting without modifying anything
	terraform fmt -check -recursive

validate: ## terraform validate on every module and every example
	@set -e; for d in $(MODULES) $(EXAMPLES); do \
		echo "==> $$d"; \
		terraform -chdir=$$d init -backend=false -input=false > /dev/null; \
		terraform -chdir=$$d validate; \
	done

# The examples belong to the test suite and not just to `validate`: validate
# evaluates neither variable validations nor preconditions, so it does not see
# wiring errors. With a mocked provider the examples' plan runs without credentials.
test: ## terraform test on every module and example that has tests
	@set -e; for d in $(MODULES) $(EXAMPLES); do \
		if [ -d "$$d/tests" ]; then \
			echo "==> $$d"; \
			terraform -chdir=$$d init -backend=false -input=false > /dev/null; \
			terraform -chdir=$$d test; \
		fi; \
	done

lint: ## tflint on every module
	@set -e; for d in $(MODULES); do echo "==> $$d"; tflint --chdir=$$d; done

docs: ## Regenerate the module READMEs with terraform-docs
	terraform-docs --config .terraform-docs.yml .

# Present only in checkouts that have the migration tooling locally: `tools/` is
# not part of the repo. Outside `check` for that reason.
tools-test: ## Test the migration tooling, if present locally
	@if [ -d tools/tests ]; then python3 -m unittest discover -s tools/tests; \
	else echo "tools/ not present in this checkout: nothing to run"; fi

check: fmt-check validate test ## Everything that runs without AWS credentials

clean: ## Remove the Terraform working directories
	find . -type d -name .terraform -prune -exec rm -rf {} +
