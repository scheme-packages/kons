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
ARGS_SRCDIR = vendor/scm-args/src
CONDUIT_SRCDIR = vendor/conduit/src
VENDOR_SRCDIRS = $(ARGS_SRCDIR),$(CONDUIT_SRCDIR)
VENDOR_SUBMODULES = vendor/scm-args vendor/conduit
.PHONY: fmt check check-all check-required clean-test-cache unit-tests akku-tests integration-tests self-verify verify verify-capy ci-unit ci-manager-install install uninstall install-verify install-script-verify clean

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

ci-manager-install:
	@echo "install verification is not part of the unit test suite"

integration-tests:
	@echo "integration suite removed"

check-required:
	@command -v $(CAPY) >/dev/null
	$(MAKE) check-all

self-verify:
	@echo "self verification is not part of the unit test suite"

install:
	git submodule update --init --recursive $(VENDOR_SUBMODULES)
	KONS_SCHEME="$(KONS_SCHEME)" KONS_HOME="$(KONS_HOME)" KONS_VENDORDIR="$(CURDIR)/vendor" ./bin/kons --scheme "$(KONS_SCHEME)" install --compile-mode compiled --jobs 4 --path . --root "$(DESTDIR)$(KONS_HOME)" --directory "$(DESTDIR)$(bindir)" --name kons
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
