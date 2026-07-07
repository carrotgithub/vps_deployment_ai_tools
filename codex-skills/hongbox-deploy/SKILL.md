---
name: hongbox-deploy
description: AI-assisted deployment of HongBox/Hong AI Box services on Debian or Ubuntu VPS hosts. Use when Codex needs to plan, preflight, apply, inspect, or troubleshoot server deployments for Maintenance, Nginx, Docker, CliproxyAPI, New-API, or Pi using the repository's hongbox CLI and profile-driven workflow.
---

# HongBox Deploy

## Workflow

Use HongBox as a deterministic executor, not as a chatty terminal menu. Keep all human interaction in the Codex conversation, then call `hongbox` with explicit arguments or a generated `.env` profile.

1. Clarify the target service set, access mode, domains/IPs, database choice, and deployment mode.
2. Generate or inspect a profile with non-secret deployment choices.
3. Run `plan` and explain the planned system changes to the user.
4. Run `preflight` and address failures before installation.
5. Run `apply` only after explicit user confirmation, passing `--yes`.
6. Run `status` or `doctor` after deployment and summarize results.

Never print secret values. If a password is supplied, refer to it as provided/hidden. Prefer generated credentials and report the credential file path after deployment.

## Commands

Use `scripts/hongbox-run.sh` to invoke the repo-local CLI from any working directory:

```bash
./scripts/hongbox-run.sh plan --profile deploy.env
./scripts/hongbox-run.sh preflight --profile deploy.env
sudo ./scripts/hongbox-run.sh apply --profile deploy.env --yes
./scripts/hongbox-run.sh status
./scripts/hongbox-run.sh doctor --profile deploy.env
```

If the script cannot find the repository, set `HONGBOX_REPO_DIR=/path/to/hong-ai-box`.

## Profile

Use `.env` profiles for repeatable AI-generated deployments:

```bash
HONGBOX_SERVICES="maintenance,nginx,docker,new-api"
HONGBOX_ACCESS_MODE="domain"
HONGBOX_NEWAPI_DOMAIN="api.example.com"
HONGBOX_DB_TYPE="postgresql"
```

For multiple Web services, use distinct domains:

```bash
HONGBOX_SERVICES="maintenance,nginx,docker,cliproxyapi,new-api"
HONGBOX_ACCESS_MODE="domain"
HONGBOX_CLIPROXY_DOMAIN="cpa.example.com"
HONGBOX_NEWAPI_DOMAIN="api.example.com"
```

## Safety

Before `apply`, state that HongBox may install packages, enable systemd services, write under `/opt`, `/etc/nginx`, `/etc/docker`, `/var/log/vps-deploy`, and `/var/lib/hongaibox`, and may request/replace Nginx service configs for selected Web services.

Do not run destructive uninstall, volume deletion, SSH hardening changes, or production certificate replacement unless the user explicitly asks and confirms the specific action.

## References

- Read `references/services.md` when choosing service names, dependencies, and profile variables.
- Read `references/safety.md` before applying changes on a real VPS.
