# SA Check

Lightweight, push-based server health monitoring for cPanel/WHM fleets, with
all alert rules managed centrally in [n8n](https://n8n.io).

**Version 1.1.0** · MIT License
**Designed and developed by Eng. Samir Abou El Khair**

## Why

Monitoring dozens of production servers that host client sites should not
mean opening inbound ports or editing every server when a rule changes.
SA Check reverses the usual model:

- Each server runs a tiny script from cron and **pushes** its status to n8n
  over outbound HTTPS. No inbound ports, no agents listening.
- **n8n decides what is an alert.** Ignore a service fleet-wide, or on one
  server, by editing one node. Nothing to redeploy on the servers.
- Alerts are **de-duplicated**: one message when the status changes, then an
  hourly reminder while the problem persists, instead of one per minute.

## Architecture

```
 server (cron, every minute)
   sa-check.sh ──HTTPS POST──▶ n8n webhook
                                  │
                           Company Lookup  (IP → company, rules, dedup)
                                  │
                    (also de-duplicates alerts)
                                  │
                              IF status == ok
                       ┌──────────┴──────────┐
                     true                   false
                  (All good)             Telegram
```

## What is checked

Apache (`httpd`/`apache2`), MySQL/MariaDB (`mysqld`/`mariadb`/`mysql`),
Exim, Dovecot, PHP-FPM, plus disk usage, RAM usage and load average.
Service unit names are auto-detected.

## Install on a server

Run as root. Pin to a release tag so every server runs a known version:

```bash
curl -fsSL https://raw.githubusercontent.com/<user>/sa-check/v1.1.0/scripts/install.sh | \
  SA_REPO="<user>/sa-check" SA_REF="v1.1.0" \
  SA_WEBHOOK_URL="https://your-n8n.example.com/webhook/sa-check" bash
```

The installer downloads the script, validates its syntax, stores the webhook
URL in `/etc/sa-check.conf` (mode 600) and adds the cron entry
`* * * * * /usr/local/bin/sa-check.sh > /dev/null 2>&1`. The output redirect
matters: without it cron e-mails the script's output every minute.

**Upgrade:** run the same command with a newer `SA_REF`. The webhook URL is
kept, so `SA_WEBHOOK_URL` may be omitted.

## Set up n8n

1. Import `n8n/sa-check-workflow.json`.
2. Open the **Telegram** node, select your Telegram credential and set your
   chat ID.
3. Open **Company Lookup**. Servers register themselves automatically with
   the hostname they report; you only need to list a server if you want to
   override its name, one per line: `203.0.113.10 = server.example.com`
   (no quotes or commas needed).
4. **Publish** the workflow. The production webhook is
   `https://<your-n8n>/webhook/sa-check`.

## Alert rules (all in the Company Lookup node)

| Setting | Purpose |
|---|---|
| `ignoredServices` | Services that never alert, on any server |
| `DEDUP` / `REMINDER_MS` | De-duplication on/off, and the reminder interval (default 1 h) |
| `perServerIgnoredServices` | Services ignored on specific IPs only |
| Disk / RAM ≥ 90 % | Raises a `warning` |

## Testing

```bash
node tests/test-workflow.js
```

Runs the real Company Lookup code from the workflow JSON against a mocked n8n
runtime (naming, status rules, de-duplication, reminders, recovery) and checks
the shell scripts with `bash -n`. Requires Node.js 18+, nothing else.

## Security notes

- Never commit your Telegram bot token, chat ID or real server list. They
  live in n8n credentials and the n8n workflow, not in this repository.
- A public webhook accepts anyone's POST. Set `SA_TOKEN` when installing and
  add Header Auth (`X-SA-Token`) to the n8n webhook so only your servers can
  raise alerts.
- `/etc/sa-check.conf` is created with mode 600 and read only by root's cron.

## Versioning

[Semantic Versioning](https://semver.org/). Releases are Git tags (`v1.1.0`);
see [CHANGELOG.md](CHANGELOG.md). The version is also reported in every
payload, so n8n can show which servers run which release.

## Author

Eng. Samir Abou El Khair

## License

MIT, copyright (c) 2026 Eng. Samir Abou El Khair. See [LICENSE](LICENSE).
Redistributions must keep the copyright notice.
