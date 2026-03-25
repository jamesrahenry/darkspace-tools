# Darkspace Tools Makefile
# Common operations for deployment, diagnostics, and management

.PHONY: help setup deploy teardown diagnose status lint check-sanitization add-service

PROFILE ?= netflow
SERVICE ?= cowrie
SHELL := /bin/bash

help: ## Show this help
	@echo "Darkspace Tools - Available Commands"
	@echo ""
	@echo "  make setup                      Interactive configuration wizard"
	@echo "  make deploy PROFILE=netflow      Deploy infrastructure (netflow|ids|honeypot-lite|honeypot-full)"
	@echo "  make teardown                    Destroy all infrastructure"
	@echo "  make diagnose                    Run end-to-end diagnostics"
	@echo "  make status                      Quick health check"
	@echo "  make lint                        Syntax check playbooks and scripts"
	@echo "  make check-sanitization          Verify no real IPs in codebase"
	@echo "  make add-service SERVICE=cowrie   Add a honeypot service (honeypot-lite)"
	@echo ""
	@echo "Profiles:"
	@echo "  netflow        GRE tunnel + kernel-level traffic monitoring (~50MB, 5 min)"
	@echo "  ids            Above + Suricata IDS on target IP (~300MB, 15 min)"
	@echo "  honeypot-lite  Above + selected honeypot services (~500MB, 20 min)"
	@echo "  honeypot-full  Above + full T-Pot with ELK stack (~3GB, 60 min)"

setup: ## Interactive configuration wizard
	@sudo bash scripts/setup.sh

deploy: ## Deploy with selected profile
	@echo "Deploying with profile: $(PROFILE)"
	@export DARKSPACE_PROFILE=$(PROFILE) && sudo -E bash scripts/deploy.sh

teardown: ## Destroy all infrastructure (requires confirmation)
	@sudo bash scripts/teardown.sh

diagnose: ## Run end-to-end connectivity diagnostics
	@sudo bash scripts/diagnose.sh

status: ## Quick health check
	@echo "=== Quick Status ==="
	@echo ""
	@echo "GRE Tunnel:"
	@ip link show darkspace-gre 2>/dev/null | head -2 || echo "  Not configured"
	@echo ""
	@echo "iptables NAT rules:"
	@sudo iptables -t nat -L PREROUTING -n 2>/dev/null | grep -c DNAT || echo "  0 DNAT rules"
	@echo ""
	@echo "Traffic-host droplets:"
	@command -v doctl >/dev/null 2>&1 && doctl compute droplet list --format Name,Status,PrivateIPv4 --no-header 2>/dev/null | grep traffic-host || echo "  None found"
	@echo ""
	@echo "For detailed diagnostics: make diagnose"

lint: ## Syntax check all playbooks and scripts
	@echo "=== Checking Ansible playbooks ==="
	@for f in ansible/*.yml; do \
		echo "  Checking $$f..."; \
		ansible-playbook --syntax-check "$$f" 2>/dev/null && echo "    OK" || echo "    FAILED"; \
	done
	@echo ""
	@echo "=== Checking shell scripts ==="
	@if command -v shellcheck >/dev/null 2>&1; then \
		for f in scripts/*.sh; do \
			echo "  Checking $$f..."; \
			shellcheck -S warning "$$f" && echo "    OK" || echo "    WARNINGS"; \
		done; \
	else \
		echo "  shellcheck not installed (apt install shellcheck)"; \
	fi

check-sanitization: ## Verify no real/private IPs leaked in codebase
	@echo "=== Sanitization Check ==="
	@echo "Checking for known private IPs..."
	@FOUND=0; \
	for pattern in '64\.114\.50\.50' '198\.166\.191\.102' '143\.110\.214\.101' '10\.118\.' '10\.116\.' 'canoe' 'cctx' 'CCTX'; do \
		MATCHES=$$(grep -rn "$$pattern" --include='*.yml' --include='*.sh' --include='*.md' --include='*.py' --include='*.j2' --include='*.cfg' . 2>/dev/null | grep -v '.git/' | grep -v 'check-sanitization' || true); \
		if [ -n "$$MATCHES" ]; then \
			echo "  FOUND '$$pattern':"; \
			echo "$$MATCHES" | sed 's/^/    /'; \
			FOUND=1; \
		fi; \
	done; \
	if [ "$$FOUND" -eq 0 ]; then \
		echo "  All clean - no private IPs or project names found"; \
	else \
		echo ""; \
		echo "  WARNING: Found sensitive data above. Please sanitize before publishing."; \
	fi

add-service: ## Add a honeypot service (for honeypot-lite profile)
	@echo "Adding service: $(SERVICE)"
	@echo "Available: cowrie, dionaea, honeytrap, mailoney, suricata"
	@echo "TODO: Implement service addition to running deployment"
