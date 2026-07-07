# HongBox Deployment Safety

## Required Gates

Always run `plan` before `apply`.

Always run `preflight` before `apply` on a real host unless the user explicitly asks to skip it.

Only run `apply` after the user has confirmed the plan. Use `--yes` or `HONGBOX_CONFIRM_APPLY=yes` only after that confirmation.

## Sensitive Values

Do not print passwords, API keys, database passwords, or generated secrets.

Prefer automatic secret generation. Report credential file paths instead of values.

If the user provides a secret in chat, avoid repeating it back.

## High-Risk Areas

Call out these areas in the plan summary:

- Package installation through `apt`
- Systemd service enable/restart
- Nginx config writes under `/etc/nginx`
- Docker daemon config writes under `/etc/docker`
- Docker Compose state under `/opt/docker-services`
- SSL certificate issuance or replacement
- Maintenance baseline changes such as fail2ban, swap, journald, and Docker log rotation

Do not run uninstall scripts, delete Docker volumes, delete SSL files, or remove service directories unless the user explicitly asks for that exact operation.
