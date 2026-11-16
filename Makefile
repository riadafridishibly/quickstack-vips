VERSION := $(shell cat VERSION)
TARGETS := linux-amd64 linux-arm64 freebsd-amd64
TARGET ?= linux-amd64
NAME := quickstack-vips-$(VERSION)
# Linux distributions the test runs on: the oldest glibc we support and a
# current one.
TEST_IMAGES := rockylinux:8 debian:trixie-slim

.PHONY: help kit dist sources test test-host clean

help: ## Show targets
	@grep -E '^[a-z-]+:.*## ' $(MAKEFILE_LIST) | awk -F':.*## ' '{printf "  %-10s %s\n", $$1, $$2}'

kit: ## Build the kit for TARGET into dist/TARGET
	rm -rf dist/$(TARGET)
	docker build --build-arg TARGET=$(TARGET) --target kit --output type=local,dest=dist/$(TARGET) .

dist: sources ## Build every target and the release tarballs with SHA256SUMS
	for t in $(TARGETS); do $(MAKE) kit TARGET=$$t && tar -czf dist/$(NAME)-$$t.tar.gz -C dist/$$t . || exit 1; done
	cd dist && shasum -a 256 *.tar.gz > SHA256SUMS

sources: ## Tar the upstream sources and this build into dist/
	rm -rf dist/src
	docker build --target sources --output type=local,dest=dist/src/upstream .
	cp -R Dockerfile Makefile build.sh fetch.sh sources.txt VERSION LICENSE README.md dist/src/
	tar -czf dist/$(NAME)-sources.tar.gz -C dist/src .

test: ## Run the Linux kit in dist/TARGET on TEST_IMAGES
	for img in $(TEST_IMAGES); do \
		echo "== $$img"; \
		docker run --rm --platform linux/$(lastword $(subst -, ,$(TARGET))) \
			-v "$(CURDIR)/dist/$(TARGET):/kit:ro" -v "$(CURDIR)/testdata:/testdata:ro" -v "$(CURDIR)/test.sh:/test.sh:ro" \
			$$img /test.sh /kit /testdata || exit 1; \
	done

test-host: ## Run the kit in dist/TARGET over ssh on HOST (for FreeBSD)
	@test -n "$(HOST)" || { echo "set HOST=user@host"; exit 1; }
	tmp=$$(ssh $(HOST) mktemp -d) && \
	tar -czf - -C dist/$(TARGET) . | ssh $(HOST) "mkdir $$tmp/kit && tar -xzf - -C $$tmp/kit" && \
	tar -czf - testdata test.sh | ssh $(HOST) "tar -xzf - -C $$tmp" && \
	ssh $(HOST) "sh $$tmp/test.sh $$tmp/kit $$tmp/testdata; s=\$$?; rm -r $$tmp; exit \$$s"

clean: ## Remove dist/
	rm -rf dist
