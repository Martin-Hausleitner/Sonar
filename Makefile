# Sonar — convenience targets.
#
# Most build/test work happens via xcodebuild + scripts/release/*. This
# Makefile just exposes the few muscle-memory commands.

.PHONY: help lint lint-fix lint-swift lint-python lint-shell lint-yaml lint-actions test publish

help:
	@echo "Sonar make targets:"
	@echo "  make lint                Run Swift, Python, shell, YAML, and GitHub Actions lints"
	@echo "  make lint-fix            Auto-format Swift/Python, then run all lints"
	@echo "  make test                Run the full xcodebuild test suite"
	@echo "  make publish             Auto-bump patch + cut a release"
	@echo "  make publish VERSION=X   Cut a release with explicit version"

lint: lint-swift lint-python lint-shell lint-yaml lint-actions

lint-fix:
	swiftformat sonar sonarTests sonarUITests
	ruff format scripts/e2e sonar-server
	ruff check --fix scripts/e2e sonar-server
	$(MAKE) lint

lint-swift:
	swiftformat sonar sonarTests sonarUITests --lint
	swiftlint lint --strict

lint-python:
	ruff format --check scripts/e2e sonar-server
	ruff check scripts/e2e sonar-server

lint-shell:
	shellcheck scripts/coverage/*.sh scripts/e2e/*.sh scripts/release/*.sh

lint-yaml:
	yamllint project.yml .github/workflows

lint-actions:
	actionlint .github/workflows/*.yml

test:
	xcodebuild test \
	  -project Sonar.xcodeproj \
	  -scheme Sonar \
	  -destination 'platform=iOS Simulator,name=iPhone 16 Pro'

publish:
	@./scripts/release/publish.sh $(VERSION)
