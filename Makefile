CAPY ?= capy
GAUCHE ?= gosh
GUILE ?= guile
CHIBI ?= chibi-scheme
CHEZ ?= scheme
SCHEMAT ?= schemat
PREFIX ?= $(HOME)/.kons
KONS_HOME ?= $(PREFIX)
bindir ?= $(KONS_HOME)/bin
libdir ?= $(KONS_HOME)/lib
KONS_SCHEME ?= capy
KONS_RUNTIME_SCHEME ?= $(KONS_SCHEME)
KONS_MANAGER_SCHEME ?= gauche
KONS_TEST_HOME ?= /tmp/kons-test-home
KONS_TEST_CACHE_HOME ?= /tmp/kons-capy-cache
KONS_BIN = ./bin/kons
TEST_ENV = XDG_CACHE_HOME=$(KONS_TEST_CACHE_HOME) KONS_HOME=$(KONS_TEST_HOME) KONS_SCHEME=$(KONS_SCHEME)
KONS = $(TEST_ENV) $(KONS_BIN)
ABS_KONS = $(TEST_ENV) $(abspath $(KONS_BIN))
RUN_TEST = $(TEST_ENV) $(CAPY) -L $(VENDOR_SRCDIRS),src -s
INTEGRATION_FIXTURES = tests/integration/fixtures
INTEGRATION_KONS_HOME ?= /tmp/kons-integration-kons-$(KONS_SCHEME)
INTEGRATION_KONS = XDG_CACHE_HOME=$(KONS_TEST_CACHE_HOME) KONS_HOME=$(INTEGRATION_KONS_HOME) KONS_SCHEME=$(KONS_SCHEME) $(INTEGRATION_KONS_HOME)/bin/kons
ARGS_SRCDIR = vendor/scm-args/src
CONDUIT_SRCDIR = vendor/conduit/src
VENDOR_SRCDIRS = $(ARGS_SRCDIR),$(CONDUIT_SRCDIR)
RUN_MANAGER_TEST = $(TEST_ENV) sh -c '\
  case "$$1" in \
    capy) exec "$(CAPY)" -L "$(VENDOR_SRCDIRS),src" -s "$$2" ;; \
    gauche|gosh) exec "$(GAUCHE)" -r7 -I "$(ARGS_SRCDIR)" -I "$(CONDUIT_SRCDIR)" -I src "$$2" ;; \
    guile) exec "$(GUILE)" --r7rs -L "$(ARGS_SRCDIR)" -L "$(CONDUIT_SRCDIR)" -L src "$$2" ;; \
    chibi|chibi-scheme) exec "$(CHIBI)" -I "$(ARGS_SRCDIR)" -I "$(CONDUIT_SRCDIR)" -I src "$$2" ;; \
    *) printf "%s\n" "unsupported manager test scheme: $$1" >&2; exit 1 ;; \
  esac' manager-test
VENDOR_SUBMODULES = vendor/scm-args vendor/conduit
.PHONY: fmt check check-all check-required clean-test-cache unit-tests akku-tests integration-tests self-verify verify verify-capy ci-unit ci-implementation ci-manager-install ci-runtime-r7rs ci-runtime-r6rs ci-integration install uninstall install-verify install-script-verify clean

fmt:
	$(SCHEMAT) '**/*.scm' '**/*.sld' '**/*.sls'

check: unit-tests

check-all: unit-tests

clean-test-cache:
	rm -rf $(KONS_TEST_CACHE_HOME)

unit-tests: clean-test-cache
	$(RUN_TEST) tests/akku-format.scm
	$(RUN_TEST) tests/jobs.scm
	$(RUN_TEST) tests/implementation.scm
	$(RUN_TEST) tests/library-discovery.scm
	$(RUN_TEST) tests/metadata.scm
	$(RUN_TEST) tests/conditions.scm
	$(RUN_TEST) tests/translation.scm
	$(RUN_TEST) tests/status-shared.scm
	$(RUN_TEST) tests/tree-clean.scm
	$(RUN_TEST) tests/akku-cli.scm
	$(RUN_TEST) tests/akku-config.scm
	$(RUN_TEST) tests/lock.scm
	$(RUN_TEST) tests/akku-lock.scm
	$(RUN_TEST) tests/snow-resolver.scm
	$(RUN_TEST) tests/akku-resolver.scm
	$(RUN_TEST) tests/resolver.scm
	$(RUN_TEST) tests/compat-scan.scm

akku-tests: clean-test-cache
	$(RUN_TEST) tests/akku-format.scm
	$(RUN_TEST) tests/akku-config.scm
	$(RUN_TEST) tests/akku-resolver.scm
	$(RUN_TEST) tests/akku-lock.scm
	$(RUN_TEST) tests/akku-cli.scm

ci-unit: unit-tests

ci-implementation: KONS_TEST_HOME = /tmp/kons-test-home-implementation-$(KONS_SCHEME)
ci-implementation: KONS_TEST_CACHE_HOME = /tmp/kons-capy-cache-implementation-$(KONS_SCHEME)
ci-implementation:
	$(RUN_MANAGER_TEST) "$(KONS_SCHEME)" tests/implementation.scm

ci-manager-install:
	rm -rf /tmp/kons-manager-install-$(KONS_SCHEME)
	./install.sh --source . --kons-home /tmp/kons-manager-install-$(KONS_SCHEME) --scheme "$(KONS_SCHEME)" --non-interactive
	test -f /tmp/kons-manager-install-$(KONS_SCHEME)/lib/bin/kons/src/kons/akku/keys.d/akku-archive-2018.gpg
	KONS_HOME=/tmp/kons-manager-install-$(KONS_SCHEME) KONS_SCHEME="$(KONS_SCHEME)" /tmp/kons-manager-install-$(KONS_SCHEME)/bin/kons --help >/dev/null
	KONS_HOME=/tmp/kons-manager-install-$(KONS_SCHEME) KONS_SCHEME="$(KONS_SCHEME)" /tmp/kons-manager-install-$(KONS_SCHEME)/bin/kons doctor

ci-runtime-r7rs: KONS_TEST_HOME = /tmp/kons-test-home-r7rs-$(KONS_SCHEME)-$(KONS_RUNTIME_SCHEME)
ci-runtime-r7rs: KONS_TEST_CACHE_HOME = /tmp/kons-capy-cache-r7rs-$(KONS_SCHEME)-$(KONS_RUNTIME_SCHEME)
ci-runtime-r7rs:
	rm -rf /tmp/kons-ci-r7rs-$(KONS_RUNTIME_SCHEME)
	$(ABS_KONS) --scheme "$(KONS_RUNTIME_SCHEME)" new --directory /tmp/kons-ci-r7rs-$(KONS_RUNTIME_SCHEME) --name ci/r7rs
	cd /tmp/kons-ci-r7rs-$(KONS_RUNTIME_SCHEME) && $(ABS_KONS) --scheme "$(KONS_RUNTIME_SCHEME)" test
	cd /tmp/kons-ci-r7rs-$(KONS_RUNTIME_SCHEME) && $(ABS_KONS) --scheme "$(KONS_RUNTIME_SCHEME)" run

ci-runtime-r6rs: KONS_TEST_HOME = /tmp/kons-test-home-r6rs-$(KONS_SCHEME)-$(KONS_RUNTIME_SCHEME)
ci-runtime-r6rs: KONS_TEST_CACHE_HOME = /tmp/kons-capy-cache-r6rs-$(KONS_SCHEME)-$(KONS_RUNTIME_SCHEME)
ci-runtime-r6rs:
	rm -rf /tmp/kons-ci-r6rs-$(KONS_RUNTIME_SCHEME)
	$(ABS_KONS) --scheme "$(KONS_RUNTIME_SCHEME)" --dialect r6rs new --directory /tmp/kons-ci-r6rs-$(KONS_RUNTIME_SCHEME) --name ci/r6rs
	cd /tmp/kons-ci-r6rs-$(KONS_RUNTIME_SCHEME) && $(ABS_KONS) --scheme "$(KONS_RUNTIME_SCHEME)" --dialect r6rs test
	cd /tmp/kons-ci-r6rs-$(KONS_RUNTIME_SCHEME) && $(ABS_KONS) --scheme "$(KONS_RUNTIME_SCHEME)" --dialect r6rs run

ci-integration: KONS_TEST_HOME = /tmp/kons-test-home-integration-$(KONS_SCHEME)
ci-integration: KONS_TEST_CACHE_HOME = /tmp/kons-capy-cache-integration-$(KONS_SCHEME)
ci-integration:
	rm -rf /tmp/kons-integration-$(KONS_SCHEME) /tmp/kons-integration-lib-$(KONS_SCHEME) /tmp/kons-integration-install-$(KONS_SCHEME) "$(INTEGRATION_KONS_HOME)"
	$(ABS_KONS) --scheme "$(KONS_SCHEME)" new --directory /tmp/kons-integration-$(KONS_SCHEME) --name ci/integration
	cd /tmp/kons-integration-$(KONS_SCHEME) && $(ABS_KONS) --scheme "$(KONS_SCHEME)" check
	cd /tmp/kons-integration-$(KONS_SCHEME) && $(ABS_KONS) --scheme "$(KONS_SCHEME)" test
	cd /tmp/kons-integration-$(KONS_SCHEME) && $(ABS_KONS) --scheme "$(KONS_SCHEME)" run
	cd /tmp/kons-integration-$(KONS_SCHEME) && $(ABS_KONS) --scheme "$(KONS_SCHEME)" install --root /tmp/kons-integration-install-$(KONS_SCHEME) --directory /tmp/kons-integration-install-$(KONS_SCHEME)/bin --name integration
	/tmp/kons-integration-install-$(KONS_SCHEME)/bin/integration
	$(ABS_KONS) --scheme "$(KONS_SCHEME)" new --lib --directory /tmp/kons-integration-lib-$(KONS_SCHEME) --name ci/integration-lib
	cd /tmp/kons-integration-lib-$(KONS_SCHEME) && $(ABS_KONS) --scheme "$(KONS_SCHEME)" check
	cd /tmp/kons-integration-lib-$(KONS_SCHEME) && $(ABS_KONS) --scheme "$(KONS_SCHEME)" test
	rm -rf /tmp/kons-integration-features-$(KONS_SCHEME)
	cp -R "$(INTEGRATION_FIXTURES)/features" /tmp/kons-integration-features-$(KONS_SCHEME)
	cd /tmp/kons-integration-features-$(KONS_SCHEME) && $(ABS_KONS) --scheme "$(KONS_SCHEME)" --features tls check
	cd /tmp/kons-integration-features-$(KONS_SCHEME) && $(ABS_KONS) --scheme "$(KONS_SCHEME)" --features tls test
	cd /tmp/kons-integration-features-$(KONS_SCHEME) && $(ABS_KONS) --scheme "$(KONS_SCHEME)" --features tls run | grep 'feature-cond:tls'
	if [ "$(KONS_SCHEME)" = capy ] || [ "$(KONS_SCHEME)" = guile ]; then \
	  cd /tmp/kons-integration-features-$(KONS_SCHEME) && $(ABS_KONS) --scheme "$(KONS_SCHEME)" --features tls run | grep 'cond-expand:other'; \
	else \
	  cd /tmp/kons-integration-features-$(KONS_SCHEME) && $(ABS_KONS) --scheme "$(KONS_SCHEME)" --features tls run | grep 'cond-expand:r7rs'; \
	fi
	rm -rf /tmp/kons-integration-build-hooks-$(KONS_SCHEME)
	cp -R "$(INTEGRATION_FIXTURES)/build-hooks" /tmp/kons-integration-build-hooks-$(KONS_SCHEME)
	cd /tmp/kons-integration-build-hooks-$(KONS_SCHEME) && $(ABS_KONS) --scheme "$(KONS_SCHEME)" check
	cd /tmp/kons-integration-build-hooks-$(KONS_SCHEME) && $(ABS_KONS) --scheme "$(KONS_SCHEME)" test
	cd /tmp/kons-integration-build-hooks-$(KONS_SCHEME) && $(ABS_KONS) --scheme "$(KONS_SCHEME)" run | grep 'build-hook generated'
	rm -rf /tmp/kons-integration-registry-$(KONS_SCHEME)
	cp -R "$(INTEGRATION_FIXTURES)/registry-args" /tmp/kons-integration-registry-$(KONS_SCHEME)
	cd /tmp/kons-integration-registry-$(KONS_SCHEME) && $(ABS_KONS) --scheme "$(KONS_SCHEME)" fetch
	cd /tmp/kons-integration-registry-$(KONS_SCHEME) && $(ABS_KONS) --scheme "$(KONS_SCHEME)" test
	cd /tmp/kons-integration-registry-$(KONS_SCHEME) && $(ABS_KONS) --scheme "$(KONS_SCHEME)" run | grep 'registry:args:#t'
	cd /tmp/kons-integration-registry-$(KONS_SCHEME) && $(ABS_KONS) --scheme "$(KONS_SCHEME)" vendor --directory vendor/kons
	./install.sh --source . --kons-home "$(INTEGRATION_KONS_HOME)" --scheme "$(KONS_SCHEME)" --non-interactive
	test -f "$(INTEGRATION_KONS_HOME)/lib/bin/kons/src/kons/akku/keys.d/akku-archive-2018.gpg"
	rm -rf /tmp/kons-integration-akku-$(KONS_SCHEME)
	$(INTEGRATION_KONS) --scheme "$(KONS_SCHEME)" new --lib --directory /tmp/kons-integration-akku-$(KONS_SCHEME) --name ci/akku
	cd /tmp/kons-integration-akku-$(KONS_SCHEME) && $(INTEGRATION_KONS) --scheme "$(KONS_SCHEME)" add --akku xunit --version '0.0.0-akku.21.0b4ede2'
	cd /tmp/kons-integration-akku-$(KONS_SCHEME) && $(INTEGRATION_KONS) --scheme "$(KONS_SCHEME)" fetch
	test -d "$(INTEGRATION_KONS_HOME)/store/akku"
	rm -rf /tmp/kons-integration-snow-$(KONS_SCHEME)
	$(ABS_KONS) --scheme "$(KONS_SCHEME)" new --lib --directory /tmp/kons-integration-snow-$(KONS_SCHEME) --name ci/snow
	cd /tmp/kons-integration-snow-$(KONS_SCHEME) && $(ABS_KONS) --scheme "$(KONS_SCHEME)" add --snow retropikzel/system --version '^1.0'
	cd /tmp/kons-integration-snow-$(KONS_SCHEME) && $(ABS_KONS) --scheme "$(KONS_SCHEME)" fetch
	test -d "$(KONS_TEST_HOME)/store/snow"

integration-tests:
	$(MAKE) ci-integration

check-required:
	@command -v $(CAPY) >/dev/null
	$(MAKE) check-all

self-verify:
	@echo "self verification is not part of the unit test suite"

install:
	git submodule update --init --recursive $(VENDOR_SUBMODULES)
	KONS_SCHEME="$(KONS_SCHEME)" KONS_HOME="$(KONS_HOME)" KONS_VENDORDIR="$(CURDIR)/vendor" ./bin/kons --scheme "$(KONS_SCHEME)" install --compile-mode compiled --jobs 4 --path . --root "$(DESTDIR)$(KONS_HOME)" --directory "$(DESTDIR)$(bindir)" --name kons
	install -d "$(DESTDIR)$(KONS_HOME)/lib/bin/kons/src/kons/akku/keys.d"
	install -m 0644 "src/kons/akku/keys.d/akku-archive-2018.gpg" "$(DESTDIR)$(KONS_HOME)/lib/bin/kons/src/kons/akku/keys.d/akku-archive-2018.gpg"
	install -d "$(DESTDIR)$(KONS_HOME)"
	{ \
	  printf '%s\n' '# kons environment (POSIX sh)'; \
	  printf '%s\n' '# Source this from your shell rc file:'; \
	  printf '%s\n' '#   . "$(KONS_HOME)/env"'; \
	  printf '%s\n' ''; \
	  printf '%s\n' 'case ":$$PATH:" in'; \
	  printf '%s\n' '  *":$(bindir):"*) ;;'; \
	  printf '%s\n' '  *) PATH="$(bindir):$$PATH" ;;'; \
	  printf '%s\n' 'esac'; \
	  printf '%s\n' 'export PATH'; \
	  printf '%s\n' ''; \
	  printf '%s\n' 'KONS_HOME="$(KONS_HOME)"'; \
	  printf '%s\n' 'KONS_SCHEME="$(KONS_SCHEME)"'; \
	  printf '%s\n' 'SCHEME="$(KONS_SCHEME)"'; \
	  printf '%s\n' 'export KONS_HOME KONS_SCHEME SCHEME'; \
	} >"$(DESTDIR)$(KONS_HOME)/env"
	{ \
	  printf '%s\n' '# kons environment (fish)'; \
	  printf '%s\n' '# Source this from fish config:'; \
	  printf '%s\n' '#   source "$(KONS_HOME)/env.fish"'; \
	  printf '%s\n' ''; \
	  printf '%s\n' 'if type -q fish_add_path'; \
	  printf '%s\n' '  fish_add_path -g "$(bindir)"'; \
	  printf '%s\n' 'else'; \
	  printf '%s\n' '  if not contains "$(bindir)" $$PATH'; \
	  printf '%s\n' '    set -gx PATH "$(bindir)" $$PATH'; \
	  printf '%s\n' '  end'; \
	  printf '%s\n' 'end'; \
	  printf '%s\n' ''; \
	  printf '%s\n' 'set -gx KONS_HOME "$(KONS_HOME)"'; \
	  printf '%s\n' 'set -gx KONS_SCHEME "$(KONS_SCHEME)"'; \
	  printf '%s\n' 'set -gx SCHEME "$(KONS_SCHEME)"'; \
	} >"$(DESTDIR)$(KONS_HOME)/env.fish"
	@echo "installed kons to $(DESTDIR)$(bindir)/kons"
	@echo ""
	@echo "Add kons to PATH:"
	@echo "  bash: echo '. \"$(KONS_HOME)/env\"' >> ~/.bashrc"
	@echo "  zsh:  echo '. \"$(KONS_HOME)/env\"' >> ~/.zshrc"
	@echo "  fish: echo 'source \"$(KONS_HOME)/env.fish\"' >> ~/.config/fish/config.fish"
	@echo ""
	@echo "Try:"
	@echo "  $(bindir)/kons --help"
	@echo "  $(bindir)/kons doctor"

uninstall:
	rm -f "$(DESTDIR)$(bindir)/kons"
	rm -f "$(DESTDIR)$(KONS_HOME)/env" "$(DESTDIR)$(KONS_HOME)/env.fish"
	rm -rf "$(DESTDIR)$(libdir)/kons"

install-verify:
	@echo "install verification is not part of the unit test suite"

install-script-verify:
	@echo "install script verification is not part of the unit test suite"

verify:
	@echo "runtime verification is not part of the unit test suite"

verify-capy:
	@echo "runtime verification is not part of the unit test suite"

clean:
	rm -f kons.lock
	rm -rf .kons
	rm -rf $(KONS_TEST_HOME)
	rm -rf /tmp/kons-new /tmp/kons-new-positional /tmp/kons-new-lib
	rm -rf /tmp/kons-init /tmp/kons-init-positional /tmp/kons-init-lib
	rm -rf /tmp/kons-test-dir /tmp/kons-rooted-artifacts /tmp/kons-rooted-cwd
	rm -rf /tmp/kons-install-root /tmp/kons-install-script-root /tmp/kons-clean-store-work
	rm -f /tmp/kons-*.out /tmp/kons-*.err /tmp/kons-*.lock /tmp/kons-*.scm
	rm -rf $(KONS_TEST_CACHE_HOME)
	rm -rf /tmp/kons-command-test-cache
