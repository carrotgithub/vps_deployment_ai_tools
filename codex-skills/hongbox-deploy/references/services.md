# HongBox Services

## Service IDs

Use these IDs in `HONGBOX_SERVICES` or `--services`:

- `maintenance`: fail2ban, swap, journald limits, Docker log rotation
- `nginx`: Nginx mainline with HTTP/3/QUIC and BBR tuning
- `docker`: Docker Engine and Docker Compose plugin
- `cliproxyapi`: CliproxyAPI, default Docker Compose deployment
- `new-api`: New-API model gateway, Docker Compose deployment
- `pi`: terminal AI coding assistant

Aliases accepted by the CLI include `newapi`, `cliproxy`, `cpa`, and `all`.

## Dependencies

- `cliproxyapi` depends on `nginx` and `docker` in Docker mode.
- `cliproxyapi` depends on `nginx` in bare mode.
- `new-api` depends on `nginx` and `docker`.
- `maintenance`, `nginx`, `docker`, and `pi` have no root-level service dependencies.

Already installed dependencies are detected and skipped unless selected directly.

## Profile Variables

- `HONGBOX_SERVICES`: comma-separated service IDs
- `HONGBOX_ACCESS_MODE`: `domain`, `ip`, or `http`
- `HONGBOX_DOMAIN`: single Web service endpoint
- `HONGBOX_CLIPROXY_DOMAIN`: CliproxyAPI endpoint
- `HONGBOX_NEWAPI_DOMAIN`: New-API endpoint
- `HONGBOX_CLIPROXY_MODE`: `docker` or `bare`
- `HONGBOX_DB_TYPE`: `postgresql` or `mysql`
- `HONGBOX_CONFIRM_APPLY`: set to `yes` only after user confirmation

Legacy `HONGAIBOX_*` variables are still accepted for compatibility, but prefer `HONGBOX_*`.
