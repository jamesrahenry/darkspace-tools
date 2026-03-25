# Contributing to Darkspace Tools

Thank you for your interest in contributing! This project welcomes contributions of all kinds.

## How to Contribute

### Reporting Issues

- Use GitHub Issues to report bugs or request features
- Include your deployment profile, OS version, and cloud provider
- Provide relevant log output (sanitize any IP addresses first)

### Submitting Changes

1. Fork the repository
2. Create a feature branch: `git checkout -b feature/my-change`
3. Make your changes
4. Test with `make lint` (requires `ansible-lint` and `shellcheck`)
5. Commit with a descriptive message
6. Push and open a Pull Request

### Code Standards

- **Shell scripts**: Must pass `shellcheck` with no warnings
- **Ansible playbooks**: Must pass `ansible-lint` and `ansible-playbook --syntax-check`
- **IP addresses**: Use RFC 5737 test ranges in examples and documentation:
  - `192.0.2.0/24` (TEST-NET-1)
  - `198.51.100.0/24` (TEST-NET-2)
  - `203.0.113.0/24` (TEST-NET-3)
- **Secrets**: Never commit real credentials. Use placeholder patterns like `CHANGE_ME_*`

### Documentation

- Update relevant docs when changing functionality
- Include profile-specific notes when changes affect only certain profiles
- Use ASCII diagrams for network topology (no external image dependencies)

### Testing

Before submitting, verify:

```bash
# Syntax check all playbooks
make lint

# Verify no real IPs leaked
make check-sanitization
```

## Profile Guidelines

When adding features, consider which profiles they apply to:

| Profile | Scope |
|---------|-------|
| `netflow` | Router-only, GRE + iptables monitoring |
| `ids` | Adds Suricata IDS on traffic-host |
| `honeypot-lite` | Adds individual honeypot containers |
| `honeypot-full` | Full T-Pot with ELK stack |

## License

By contributing, you agree that your contributions will be licensed under the MIT License.
