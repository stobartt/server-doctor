SHELL := /bin/bash

PROFILE ?= standard
SINCE ?= 24h
OUTPUT ?= $(CURDIR)/artifacts
OBSERVE_SECONDS ?=
MAX_REPORT_MIB ?= 1024
ENCRYPT_TO ?=
ARCHIVE ?=
USER_INSTALL_DIR ?= $(HOME)/.local/share/server-doctor
USER_LAUNCHER ?= $(HOME)/server-doctor

DOCTOR := $(CURDIR)/bin/server-doctor
COMMON_ARGS := --profile "$(PROFILE)" --since "$(SINCE)" --output "$(OUTPUT)" --max-report-mib "$(MAX_REPORT_MIB)"
ifneq ($(strip $(OBSERVE_SECONDS)),)
COMMON_ARGS += --observe-seconds "$(OBSERVE_SECONDS)"
endif
ifneq ($(strip $(ENCRYPT_TO)),)
COMMON_ARGS += --encrypt-to "$(ENCRYPT_TO)"
endif

.PHONY: help install-user doctor audit quick standard deep verify test lint check

help:
	@$(DOCTOR) help

install-user:
	@SERVER_DOCTOR_USER_INSTALL_DIR="$(USER_INSTALL_DIR)" SERVER_DOCTOR_USER_LAUNCHER="$(USER_LAUNCHER)" bin/install-user

doctor:
	@$(DOCTOR) doctor $(COMMON_ARGS)

audit:
	@$(DOCTOR) audit $(COMMON_ARGS)

quick:
	@$(MAKE) audit PROFILE=quick

standard:
	@$(MAKE) audit PROFILE=standard

deep:
	@$(MAKE) audit PROFILE=deep

verify:
	@test -n "$(ARCHIVE)" || { echo "Usage: make verify ARCHIVE=/path/to/server-doctor_*.zip[.age]" >&2; exit 2; }
	@$(DOCTOR) verify --archive "$(ARCHIVE)"

test:
	@tests/run.sh

lint:
	@tests/lint.sh

check: lint test
