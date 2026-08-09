SHELL := /bin/bash

.DEFAULT_GOAL := help

.PHONY: help bootstrap format lint validate-manifests verify-release-policy check-no-build-downloads check-t030-ui-architecture generate-ffi verify-generated-ffi rust-build rust-test swift-test integration-test benchmark-rules benchmark-ui build test

help:
	@echo "NativeXiangqi build commands:"
	@echo "  make bootstrap                 Check required tools without installing them"
	@echo "  make generate-ffi              Regenerate the checked-in C/Rust/Swift ABI projections"
	@echo "  make rust-build                Build offline arm64 Debug and Release Rust XCFramework artifacts"
	@echo "  make format                    Format Swift and Rust scaffolding"
	@echo "  make lint                      Run bounded static repository checks"
	@echo "  make rust-test                 Run Rust ownership and C ABI smoke tests"
	@echo "  make swift-test                Run all local Swift wrapper, UI, and document tests"
	@echo "  make integration-test          Run the AppKit document/window integration suite offline"
	@echo "  make benchmark-rules           Run the fixed, offline release-rule perft benchmark"
	@echo "  make benchmark-ui              Measure the offline three-pane document and board RSS gate"
	@echo "  make verify-release-policy     Validate fail-closed Community policy"
	@echo "  make build                     Build the arm64 macOS shell application"
	@echo "  make test                      Run all introduced non-signing checks through T030"

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

check-t030-ui-architecture:
	@./scripts/check-t030-ui-architecture.py

generate-ffi:
	@./scripts/generate-ffi.sh

verify-generated-ffi:
	@./scripts/verify-generated-ffi.sh

rust-build: generate-ffi
	@./scripts/build-rust-artifacts.sh all

rust-test: generate-ffi
	@./scripts/test-rust-ffi.sh

swift-test: generate-ffi check-no-build-downloads
	@./scripts/test-swift-ffi.sh

integration-test: generate-ffi check-no-build-downloads
	@./scripts/integration-test.sh

benchmark-rules: generate-ffi
	@./scripts/benchmark-rules.sh

benchmark-ui: check-no-build-downloads
	@./scripts/benchmark-ui.sh

lint:
	@./scripts/check-format.sh
	@./scripts/verify-generated-ffi.sh
	@./scripts/check-secrets.sh
	@./scripts/validate-manifests.sh
	@./scripts/verify-release-policy.sh
	@./scripts/check-no-build-downloads.sh
	@./scripts/check-t030-ui-architecture.py

build: generate-ffi verify-release-policy check-no-build-downloads
	@./scripts/build-app.sh

test: lint rust-test swift-test integration-test
