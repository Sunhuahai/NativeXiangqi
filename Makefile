SHELL := /bin/bash

.DEFAULT_GOAL := help

.PHONY: help bootstrap format lint validate-manifests verify-release-policy check-no-build-downloads build test

help:
	@echo "NativeXiangqi T000 commands:"
	@echo "  make bootstrap                 Check required tools without installing them"
	@echo "  make format                    Format Swift and Rust scaffolding"
	@echo "  make lint                      Run bounded static repository checks"
	@echo "  make verify-release-policy     Validate fail-closed Community policy"
	@echo "  make build                     Build the arm64 macOS shell application"
	@echo "  make test                      Run all T000 non-signing checks"

bootstrap:
	@./scripts/bootstrap.sh

format:
	@./scripts/format.sh

validate-manifests:
	@./scripts/validate-manifests.sh

verify-release-policy:
	@./scripts/verify-release-policy.sh

check-no-build-downloads:
	@./scripts/check-no-build-downloads.sh

lint:
	@./scripts/check-format.sh
	@./scripts/check-secrets.sh
	@./scripts/validate-manifests.sh
	@./scripts/verify-release-policy.sh
	@./scripts/check-no-build-downloads.sh

build: verify-release-policy check-no-build-downloads
	@./scripts/build-app.sh

test: lint
	@cargo test --locked --workspace
