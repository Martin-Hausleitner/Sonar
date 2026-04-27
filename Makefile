# Sonar — convenience targets.
#
# Most build/test work happens via xcodebuild + scripts/release/*. This
# Makefile just exposes the few muscle-memory commands.

.PHONY: help test publish

help:
	@echo "Sonar make targets:"
	@echo "  make test                Run the full xcodebuild test suite"
	@echo "  make publish             Auto-bump patch + cut a release"
	@echo "  make publish VERSION=X   Cut a release with explicit version"

test:
	xcodebuild test \
	  -project Sonar.xcodeproj \
	  -scheme Sonar \
	  -destination 'platform=iOS Simulator,name=iPhone 16 Pro'

publish:
	@./scripts/release/publish.sh $(VERSION)
