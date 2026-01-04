IMAGE_NAME ?= pia-wg-refresh

.PHONY: test test-download test-bundled
test:
	@./scripts/self-test.sh

test-download:
	@./scripts/self-test.sh download

test-bundled:
	@./scripts/self-test.sh bundled
