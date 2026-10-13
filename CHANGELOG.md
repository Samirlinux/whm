# Changelog

All notable changes to SA Check are documented here.
The format follows [Keep a Changelog](https://keepachangelog.com/) and the
project uses [Semantic Versioning](https://semver.org/).

## [1.1.0] - 2026-10-14

### Changed
- **Company Lookup** now auto-registers every server it sees (name, first and
  last seen) in the workflow's static data. The name table is only needed to
  override a reported hostname. Name priority: custom table, then registered
  name, then reported hostname.
- Alert de-duplication moved into **Company Lookup** (single node, one place
  for all rules). The separate **Dedup Check** node was removed and
  `IF OK` (false) now goes straight to Telegram.
- De-duplication can be switched off with `DEDUP = false`; recovery clears the
  state so the next failure alerts immediately.

### Added
- `tests/test-workflow.js`: one-command test suite (`node tests/test-workflow.js`).

### Upgrade note
- Re-import `n8n/sa-check-workflow.json`, or paste the new Company Lookup code,
  delete **Dedup Check** and connect `IF OK` (false) to **Telegram**.
  Servers do not need to be updated; the agent behaviour is unchanged.

## [1.0.0] - 2026-10-13

First public release.

### Added
- `sa-check.sh`: health agent that checks Apache, MySQL/MariaDB, Exim, Dovecot
  and PHP-FPM, plus disk, RAM and load, and pushes the result to an n8n
  webhook over outbound HTTPS (no inbound port required).
- Automatic detection of service unit names (`httpd`/`apache2`,
  `mysqld`/`mariadb`/`mysql`).
- `install.sh`: one-command installer/updater that pins to a release tag,
  validates the downloaded script, writes `/etc/sa-check.conf` and installs the
  cron job with output suppressed (no cron e-mail every minute).
- n8n workflow: central Company Lookup (IP to company, hostname fallback for
  unknown servers), central alert rules (ignored services per fleet), alert
  de-duplication with hourly reminders, and Telegram notification.
- Optional shared-secret header (`X-SA-Token`) for webhook authentication.

### Author
- Designed and developed by Eng. Samir Abou El Khair.
