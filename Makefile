CAPY ?= capy
GAUCHE ?= gosh
GUILE ?= guile
CHIBI ?= chibi-scheme
CHEZ ?= chez
PREFIX ?= $(HOME)/.kons
KONS_HOME ?= $(PREFIX)
bindir ?= $(KONS_HOME)/bin
libdir ?= $(KONS_HOME)/lib
KONS_SCHEME ?= capy
KONS_TEST_HOME ?= /tmp/kons-test-home
KONS_TEST_CACHE_HOME ?= /tmp/kons-capy-cache
KONS_BIN = ./bin/kons
TEST_ENV = XDG_CACHE_HOME=$(KONS_TEST_CACHE_HOME) KONS_HOME=$(KONS_TEST_HOME) KONS_SCHEME=$(KONS_SCHEME)
KONS = $(TEST_ENV) $(KONS_BIN)
ABS_KONS = $(TEST_ENV) $(abspath $(KONS_BIN))
RUN_TEST = $(TEST_ENV) $(CAPY) -L $(ARGS_SRCDIR),src -s
ARGS_SRCDIR = vendor/scm-args/src
VENDOR_SUBMODULE = vendor/scm-args
.PHONY: check check-all check-required clean-test-cache unit-tests integration-tests self-verify verify verify-capy install uninstall install-verify install-script-verify clean

check: unit-tests verify-capy install-verify install-script-verify

check-all: unit-tests self-verify verify-capy install-verify install-script-verify

clean-test-cache:
	rm -rf $(KONS_TEST_CACHE_HOME)

unit-tests: clean-test-cache
	$(RUN_TEST) tests/jobs.scm

integration-tests:
	@echo "integration suite removed"

check-required:
	@command -v $(CAPY) >/dev/null
	$(MAKE) check-all

self-verify:
	git submodule update --init --recursive $(VENDOR_SUBMODULE)
	$(CAPY) -L $(ARGS_SRCDIR),src -s src/kons/main.scm -- metadata >/tmp/kons-self-capy.out
	@if command -v $(GUILE) >/dev/null 2>&1; then SCHEME=guile ./bin/kons metadata >/tmp/kons-self-scheme-guile.out; else echo "skip manager SCHEME fallback Guile: $(GUILE) not found"; fi
	@if command -v $(GAUCHE) >/dev/null 2>&1; then $(GAUCHE) -r7 -I $(ARGS_SRCDIR) -I src src/kons/main.scm metadata >/tmp/kons-self-gauche.out; else echo "skip manager Gauche: $(GAUCHE) not found"; fi
	@if command -v $(GUILE) >/dev/null 2>&1; then GUILE_AUTO_COMPILE=0 $(GUILE) --r7rs -L $(ARGS_SRCDIR) -L src src/kons/main.scm metadata >/tmp/kons-self-guile.out; else echo "skip manager Guile: $(GUILE) not found"; fi
	@if command -v $(CHIBI) >/dev/null 2>&1; then $(CHIBI) -I $(ARGS_SRCDIR) -I src src/kons/main.scm metadata >/tmp/kons-self-chibi.out; else echo "skip Chibi: $(CHIBI) not found"; fi

install:
	git submodule update --init --recursive $(VENDOR_SUBMODULE)
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
	rm -rf /tmp/kons-install-root
	$(MAKE) install KONS_HOME=/tmp/kons-install-root
	test -s /tmp/kons-install-root/env
	test -s /tmp/kons-install-root/env.fish
	grep 'KONS_SCHEME="$(KONS_SCHEME)"' /tmp/kons-install-root/env >/dev/null
	/tmp/kons-install-root/bin/kons --manifest kons.scm metadata >/tmp/kons-self-metadata.out
	@if command -v $(GUILE) >/dev/null 2>&1; then SCHEME=guile /tmp/kons-install-root/bin/kons --manifest kons.scm metadata >/tmp/kons-self-installed-scheme-guile.out; fi
	@if command -v $(GAUCHE) >/dev/null 2>&1; then KONS_SCHEME=gauche /tmp/kons-install-root/bin/kons --manifest kons.scm metadata >/tmp/kons-self-installed-gauche.out; fi
	@if command -v $(GUILE) >/dev/null 2>&1; then KONS_SCHEME=guile /tmp/kons-install-root/bin/kons --manifest kons.scm metadata >/tmp/kons-self-installed-guile.out; fi
	@if command -v $(CHIBI) >/dev/null 2>&1; then KONS_SCHEME=chibi /tmp/kons-install-root/bin/kons --manifest kons.scm metadata >/tmp/kons-self-installed-chibi.out; fi
	/tmp/kons-install-root/bin/kons --manifest kons.scm install --plan >/tmp/kons-self-install-plan.out

install-script-verify:
	rm -rf /tmp/kons-install-script-root
	KONS_SOURCE="$(CURDIR)" ./install.sh --prefix /tmp/kons-install-script-root --scheme guile --non-interactive >/tmp/kons-install-script.out
	test -s /tmp/kons-install-script-root/env
	test -s /tmp/kons-install-script-root/env.fish
	grep 'KONS_SCHEME="guile"' /tmp/kons-install-script-root/env >/dev/null
	./install.sh --dry-run --source "$(CURDIR)" --prefix /tmp/kons-install-dry --scheme chibi --non-interactive >/tmp/kons-install-script-dry-run.out
	grep '+ mkdir -p ' /tmp/kons-install-script-dry-run.out >/dev/null
	test ! -e /tmp/kons-install-dry
	/tmp/kons-install-script-root/bin/kons --manifest kons.scm metadata >/tmp/kons-install-script-metadata.out
	@if command -v $(GUILE) >/dev/null 2>&1; then \
	  rm -rf /tmp/kons-install-script-no-capy-root /tmp/kons-install-script-no-capy-bin; \
	  mkdir -p /tmp/kons-install-script-no-capy-bin; \
	  printf '%s\n' '#!/bin/sh' 'exit 127' >/tmp/kons-install-script-no-capy-bin/capy; \
	  chmod +x /tmp/kons-install-script-no-capy-bin/capy; \
	  KONS_SOURCE="$(CURDIR)" PATH=/tmp/kons-install-script-no-capy-bin:$$PATH ./install.sh --prefix /tmp/kons-install-script-no-capy-root --scheme guile --non-interactive >/tmp/kons-install-script-no-capy.out; \
	  test -s /tmp/kons-install-script-no-capy-root/env; \
	  grep 'KONS_SCHEME="guile"' /tmp/kons-install-script-no-capy-root/env >/dev/null; \
	  KONS_SCHEME=guile /tmp/kons-install-script-no-capy-root/bin/kons --manifest kons.scm metadata >/tmp/kons-install-script-no-capy-metadata.out; \
	fi

verify: verify-capy

verify-capy:
	rm -rf /tmp/kons-new
	$(KONS) new --directory /tmp/kons-new --name generated/app >/tmp/kons-new.out
	$(KONS) --manifest /tmp/kons-new/kons.scm metadata >/tmp/kons-new-metadata.out
	$(KONS) --scheme capy --manifest /tmp/kons-new/kons.scm run
	$(KONS) --scheme capy --manifest /tmp/kons-new/kons.scm test
	$(KONS) --scheme capy --manifest /tmp/kons-new/kons.scm bench >/tmp/kons-new-bench.out
	$(KONS) --manifest /tmp/kons-new/kons.scm check
	rm -rf /tmp/kons-new-positional
	$(KONS) new /tmp/kons-new-positional --plan >/tmp/kons-new-positional-plan.out
	$(KONS) new /tmp/kons-new-positional >/tmp/kons-new-positional.out
	$(KONS) --manifest /tmp/kons-new-positional/kons.scm metadata >/tmp/kons-new-positional-metadata.out
	$(KONS) --scheme capy --manifest /tmp/kons-new-positional/kons.scm run
	rm -rf /tmp/kons-new-lib
	$(KONS) new --lib --directory /tmp/kons-new-lib --name generated/lib >/tmp/kons-new-lib.out
	test ! -e /tmp/kons-new-lib/src/main.scm
	$(KONS) --manifest /tmp/kons-new-lib/kons.scm metadata >/tmp/kons-new-lib-metadata.out
	$(KONS) --manifest /tmp/kons-new-lib/kons.scm check
	$(KONS) --scheme capy --manifest /tmp/kons-new-lib/kons.scm test
	$(KONS) --scheme capy --manifest /tmp/kons-new-lib/kons.scm bench >/tmp/kons-new-lib-bench.out
	$(KONS) --manifest /tmp/kons-new-lib/kons.scm run --list >/tmp/kons-new-lib-run-list.out
	@if $(KONS) --scheme capy --manifest /tmp/kons-new-lib/kons.scm run >/tmp/kons-new-lib-run.out 2>/tmp/kons-new-lib-run.err; then \
	  echo "expected library run without target to fail"; exit 1; \
	else \
	  grep 'no default run target' /tmp/kons-new-lib-run.err >/dev/null; \
	  echo "library run without target rejected"; \
	fi
	@if $(KONS) --manifest /tmp/kons-new-lib/kons.scm install --plan >/tmp/kons-new-lib-install-plan.out 2>/tmp/kons-new-lib-install-plan.err; then \
	  echo "expected library install without target to fail"; exit 1; \
	else \
	  grep 'no default install target' /tmp/kons-new-lib-install-plan.err >/dev/null; \
	  echo "library install without target rejected"; \
	fi
	rm -rf /tmp/kons-init
	mkdir -p /tmp/kons-init
	$(KONS) init --directory /tmp/kons-init --name generated/init-app --plan >/tmp/kons-init-plan.out
	$(KONS) init --directory /tmp/kons-init --name generated/init-app >/tmp/kons-init.out
	$(KONS) --manifest /tmp/kons-init/kons.scm metadata >/tmp/kons-init-metadata.out
	$(KONS) --scheme capy --manifest /tmp/kons-init/kons.scm run
	$(KONS) --scheme capy --manifest /tmp/kons-init/kons.scm test
	$(KONS) --scheme capy --manifest /tmp/kons-init/kons.scm bench >/tmp/kons-init-bench.out
	$(KONS) --manifest /tmp/kons-init/kons.scm check
	@if $(KONS) init --directory /tmp/kons-init --name generated/init-app >/tmp/kons-init-duplicate.out 2>/tmp/kons-init-duplicate.err; then \
	  echo "expected duplicate init to fail"; exit 1; \
	else \
	  grep 'kons: USAGE error:' /tmp/kons-init-duplicate.err >/dev/null; \
	  grep 'refuses to overwrite existing starter file' /tmp/kons-init-duplicate.err >/dev/null; \
	  echo "duplicate init rejected"; \
	fi
	rm -rf /tmp/kons-init-positional
	mkdir -p /tmp/kons-init-positional
	$(KONS) init /tmp/kons-init-positional --plan >/tmp/kons-init-positional-plan.out
	$(KONS) init /tmp/kons-init-positional >/tmp/kons-init-positional.out
	$(KONS) --manifest /tmp/kons-init-positional/kons.scm metadata >/tmp/kons-init-positional-metadata.out
	$(KONS) --scheme capy --manifest /tmp/kons-init-positional/kons.scm run
	rm -rf /tmp/kons-init-lib
	mkdir -p /tmp/kons-init-lib
	$(KONS) init --lib /tmp/kons-init-lib --plan >/tmp/kons-init-lib-plan.out
	$(KONS) init --lib /tmp/kons-init-lib >/tmp/kons-init-lib.out
	test ! -e /tmp/kons-init-lib/src/main.scm
	$(KONS) --manifest /tmp/kons-init-lib/kons.scm metadata >/tmp/kons-init-lib-metadata.out
	$(KONS) --manifest /tmp/kons-init-lib/kons.scm check
	$(KONS) --scheme capy --manifest /tmp/kons-init-lib/kons.scm bench >/tmp/kons-init-lib-bench.out
	rm -rf /tmp/kons-test-dir
	$(KONS) new --directory /tmp/kons-test-dir --name generated/test-dir >/tmp/kons-test-dir-new.out
	mkdir -p /tmp/kons-test-dir/custom/nested /tmp/kons-test-dir/custom/.hidden
	printf '%s\n' '(import (scheme base) (scheme write) (generated test-dir))' '' '(unless (string=? (message) "new package ok") (car (quote ())))' '(write (quote (custom-root ok)))' '(newline)' >/tmp/kons-test-dir/custom/root.scm
	printf '%s\n' '(import (scheme base) (scheme write) (generated test-dir))' '' '(unless (string=? (message) "new package ok") (car (quote ())))' '(write (quote (custom-nested ok)))' '(newline)' >/tmp/kons-test-dir/custom/nested/deep.scm
	printf '%s\n' '(import (scheme base) (scheme write) (generated test-dir))' '' '(unless (string=? (message) "new package ok") (car (quote ())))' '(write (quote (custom-sps ok)))' '(newline)' >/tmp/kons-test-dir/custom/suite.sps
	printf '%s\n' '(import (scheme base))' '(car (quote ()))' >/tmp/kons-test-dir/custom/.hidden/should-not-run.scm
	$(KONS) --manifest /tmp/kons-test-dir/kons.scm test --directory custom --plan >/tmp/kons-test-dir-plan.out
	$(KONS) --manifest /tmp/kons-test-dir/kons.scm test --directory custom nested --plan >/tmp/kons-test-dir-filter-plan.out
	$(KONS) --manifest /tmp/kons-test-dir/kons.scm test --directory custom >/tmp/kons-test-dir-run.out
	grep 'custom-root ok' /tmp/kons-test-dir-run.out >/dev/null
	grep 'custom-nested ok' /tmp/kons-test-dir-run.out >/dev/null
	grep 'custom-sps ok' /tmp/kons-test-dir-run.out >/dev/null
	@if grep 'should-not-run' /tmp/kons-test-dir-plan.out >/dev/null; then \
	  echo "hidden test directory was included"; exit 1; \
	fi
	@if $(KONS) --manifest /tmp/kons-test-dir/kons.scm test --directory missing >/tmp/kons-test-dir-missing.out 2>/tmp/kons-test-dir-missing.err; then \
	  echo "expected missing test directory to fail"; exit 1; \
	else \
	  grep 'tests directory not found' /tmp/kons-test-dir-missing.err >/dev/null; \
	  echo "missing test directory rejected"; \
	fi
	rm -rf /tmp/kons-rooted-artifacts /tmp/kons-rooted-cwd
	$(KONS) new --directory /tmp/kons-rooted-artifacts --name generated/rooted >/tmp/kons-rooted-new.out
	mkdir -p /tmp/kons-rooted-cwd
	cd /tmp/kons-rooted-cwd && $(ABS_KONS) --manifest /tmp/kons-rooted-artifacts/kons.scm update >/tmp/kons-rooted-update.out
	test -s /tmp/kons-rooted-artifacts/kons.lock
	test ! -e /tmp/kons-rooted-cwd/kons.lock
	cd /tmp/kons-rooted-cwd && $(ABS_KONS) --manifest /tmp/kons-rooted-artifacts/kons.scm build --plan >/tmp/kons-rooted-build-plan.out
	grep '(build-root "/tmp/kons-rooted-artifacts/.kons/builds/' /tmp/kons-rooted-build-plan.out >/dev/null
	grep '(compiled-root "/tmp/kons-rooted-artifacts/.kons/compiled/' /tmp/kons-rooted-build-plan.out >/dev/null
	mkdir -p /tmp/kons-rooted-artifacts/.kons/builds /tmp/kons-rooted-cwd/.kons/builds
	cd /tmp/kons-rooted-cwd && $(ABS_KONS) --manifest /tmp/kons-rooted-artifacts/kons.scm clean --plan >/tmp/kons-rooted-clean-plan.out
	grep '(default-removes "/tmp/kons-rooted-artifacts/.kons/builds"' /tmp/kons-rooted-clean-plan.out >/dev/null
	cd /tmp/kons-rooted-cwd && $(ABS_KONS) --manifest /tmp/kons-rooted-artifacts/kons.scm clean >/tmp/kons-rooted-clean.out
	test ! -d /tmp/kons-rooted-artifacts/.kons/builds
	test -d /tmp/kons-rooted-cwd/.kons/builds
	mkdir -p .kons/builds .kons/compiled
	$(KONS) clean --plan >/tmp/kons-clean-plan.out
	test -d .kons/builds
	$(KONS) clean >/tmp/kons-clean.out
	test ! -d .kons/builds
	test ! -d .kons/compiled
	rm -rf /tmp/kons-clean-store-work
	mkdir -p /tmp/kons-clean-store-work/store/sources/path
	mkdir -p /tmp/kons-clean-store-work/store/metadata/path
	cd /tmp && KONS_HOME=/tmp/kons-clean-store-work $(abspath $(KONS_BIN)) clean --store >/tmp/kons-clean-store.out
	test ! -d /tmp/kons-clean-store-work/store

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
