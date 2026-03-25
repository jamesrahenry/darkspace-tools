# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [1.0.0] - 2026-03-25

### Added
- Initial public release
- Four deployment profiles: `netflow`, `ids`, `honeypot-lite`, `honeypot-full`
- GRE tunnel automation with policy routing for correct source IP preservation
- Ansible playbooks for full infrastructure lifecycle
- Interactive setup wizard with profile selection
- Comprehensive diagnostic tooling (9-category end-to-end checks)
- DigitalOcean deployment with VPC isolation
- T-Pot v24.04.1 integration for full honeypot profile
- Suricata IDS support for standalone intrusion detection
- NetFlow-style iptables monitoring with ipset management
- Makefile for common operations
- Complete documentation suite (12 guides)
