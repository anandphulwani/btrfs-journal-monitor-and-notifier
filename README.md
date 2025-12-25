# btrfs_journal_monitor.sh — BTRFS Kernel Alerting from journald (Lookback Window + Email + Webhook)

A small, self-contained Bash script that scans **kernel logs from journald** for **BTRFS warnings/errors** over a configurable **lookback window**, then sends an **INSTANT email** and (optionally) posts to a **webhook** (great with ntfy).

Designed to run from `cron` (or systemd timers) and stay quiet unless something actionable shows up.

---

## What it does

### 1) Reads kernel logs from journald (time-bounded)
In `production` mode, it runs:

- `journalctl -k --since "<window>"`

The window is built from `--lookback=NhNm` (examples: `2h`, `45m`, `1h30m`).

### 2) Filters to BTRFS lines, excluding noisy/benign entries
It keeps kernel lines that match BTRFS, but excludes:

- Any BTRFS info messages:
  - Excludes lines matching: `kernel: BTRFS info`
- Mount scan noise:
  - Excludes lines like:
    - `kernel: BTRFS: device ... scanned by mount (123)`

If nothing remains after exclusions, the script exits successfully (and can optionally hit a heartbeat URL).

### 3) If matches remain, it alerts immediately
If any filtered lines remain, the script:

- Sends an **INSTANT email** with:
  - Hostname
  - Timestamp
  - Lookback window
  - Full command line used to invoke the script
  - Matching lines (after exclusions)
- Optionally posts the same message to:
  - `--notification-url=URL`
- Always logs actions to a log file.

### 4) Optional heartbeat ping
At the end of a run, if configured, it will:

- `curl -fsS "<heartbeat-url>"`

Useful for healthchecks / uptime monitors, proving the script ran to completion.

---

## Requirements

The script expects these tools on the host:

- `journalctl` (systemd-journald)
- `grep` (with PCRE support via `grep -P`)
- `mail` command (for email delivery)
- `curl` (optional; required only for webhook/heartbeat)

On Debian/Ubuntu, packages commonly involved:

- mail: `mailutils` (or another mail provider)
- curl: `curl`
- grep/journalctl typically present by default; journald requires systemd.

---

## Install & run (copy/paste)

### 1) Create the script
```bash
sudo vi /usr/local/sbin/btrfs_journal_monitor.sh # paste your script content
sudo chmod +x /usr/local/sbin/btrfs_journal_monitor.sh
```

### 2) Create the log file
Default log path is `/var/log/btrfs_journal_monitor.log`

```bash
sudo touch /var/log/btrfs_journal_monitor.log
sudo chown root:root /var/log/btrfs_journal_monitor.log
sudo chmod 0644 /var/log/btrfs_journal_monitor.log
```

### 3) Add cron
```bash
sudo crontab -e
```

Make sure the PATH line is present on the top, just below the comments, otherwise add it.:
```cron
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
```

Replace in the code below
01. `<EMAIL.GOES.HERE@PROVIDER.COM>` with your email, on which you want notification.
02. `<NOTIFICATION URL>` with your notification URL, on which you want notification alerts. it can be something like `http://ntfy.sh/<TOPIC-NAME-HERE>`
03. `<HEARTBEAT URL>` with your heartbeat URL, this can be a URL of uptime kuma or other uptime checkers.
```cron
0 0 * * * /bin/bash /usr/local/sbin/btrfs_journal_monitor.sh --email=<EMAIL.GOES.HERE@PROVIDER.COM> --mode=production --notification-url="<NOTIFICATION URL>" --heartbeat-url="<HEARTBEAT URL>" --lookback=24h5m
```

### 4) Ensure mail delivery works
The script uses:

```bash
mail -s "subject" recipient@example.com
```

If you don’t already have a working MTA/relay, install/configure one (for example postfix), or wire mail to a relay.

---

## Usage

### Required flags
- `--mode=production|development`
  - `production`: read from real journald kernel logs (`journalctl -k`)
  - `development`: read from local file `./journalctl_output.txt` (for testing)
- `--email=EMAIL`
  - Recipient for alert emails
- `--lookback=NhNm`
  - Lookback window, examples:
    - `--lookback=2h`
    - `--lookback=45m`
    - `--lookback=1h30m`
  - Must not be `0h0m`

### Optional flags
- `--debug`
  - Enables debug logging.
- `--log=PATH`
  - Override log path. Default: `/var/log/btrfs_journal_monitor.log`
- `--notification-url=URL`
  - POST the alert text blob to a webhook (works well with ntfy).
  - Uses headers:
    - `Title: <hostname>: BTRFS kernel alert`
    - `Priority: urgent`
    - `Tags: rotating_light,skull`
- `--heartbeat-url=URL`
  - Ping URL at the end of the run (success marker).

---

## Example runs

### Production (check last 1h30m)
```bash
sudo /usr/local/sbin/btrfs_journal_monitor.sh \
  --mode=production \
  --email=you@example.com \
  --lookback=1h30m
```

### Production with webhook + heartbeat
```bash
sudo /usr/local/sbin/btrfs_journal_monitor.sh \
  --mode=production \
  --email=you@example.com \
  --lookback=1h \
  --notification-url="http://ntfy.sh/your-topic" \
  --heartbeat-url="https://healthchecks.example.com/ping/your-id"
```

### Debug logging + custom log file
```bash
sudo /usr/local/sbin/btrfs_journal_monitor.sh \
  --mode=production \
  --email=you@example.com \
  --lookback=45m \
  --debug \
  --log=/var/log/btrfs_journal_monitor.debug.log
```

---

## Cron setup

### 1) Edit root crontab
```bash
sudo crontab -e
```

Ensure a reasonable PATH is present near the top:

```cron
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
```

### 2) Example cron entries

Check every 5 minutes, looking back 30 minutes:

```cron
*/5 * * * * /bin/bash /usr/local/sbin/btrfs_journal_monitor.sh --mode=production --email=<EMAIL.GOES.HERE@PROVIDER.COM> --lookback=30m --notification-url="<NOTIFICATION URL>" --heartbeat-url="<HEARTBEAT URL>"
```

Check every 10 minutes, looking back 1 hour:

```cron
*/10 * * * * /bin/bash /usr/local/sbin/btrfs_journal_monitor.sh --mode=production --email=<EMAIL.GOES.HERE@PROVIDER.COM> --lookback=1h
```

Note on scheduling:
- Your lookback can be larger than your interval. That can re-alert on the same line if it remains within the window.
- If you want to reduce repeats, consider:
  - shorter lookback, or
  - add dedup logic (not currently implemented).

---

## Development mode

In development mode, the script reads from:

- `./journalctl_output.txt`

This lets you test filtering/alerting without touching journald.

### Quick test workflow
1) Create a sample file:

```bash
cat > ./journalctl_output.txt <<'EOF'
kernel: BTRFS info (device sda1): scrub started
kernel: BTRFS: device fsid xyz scanned by mount (123)
kernel: BTRFS: error (device sda1): parent transid verify failed on 123 wanted 456 found 789
EOF
```

2) Run in development:

```bash
bash ./btrfs_journal_monitor.sh --mode=development --email=you@example.com --lookback=1h
```

Expected:
- The `info` line is ignored
- The `scanned by mount` line is ignored
- The remaining error triggers an INSTANT email (+ webhook if configured)

---

## Output & alerts

### Log file
- Default: `/var/log/btrfs_journal_monitor.log`
- Includes:
  - Start marker
  - Invocation command line
  - Debug configuration (when `--debug` is used)
  - Whether matches were found
  - Notification success/failure notes

### Email alert content
Emails include:
- Hostname
- Timestamp
- Lookback window
- Invoked command line
- All matching BTRFS kernel lines (after exclusions)

Subject format:
- `<hostname>: BTRFS kernel alert (INSTANT delivery)`

### Webhook payload
If `--notification-url` is set, it POSTs the same message body using curl.

---

## Tips / Troubleshooting

### 1) Email not arriving
The script only calls `mail`; it does not configure delivery. Common fixes:
- Install and configure an MTA (e.g., postfix)
- Use an SMTP relay
- Replace the mail call with your preferred notifier

### 2) journalctl permission issues
Kernel logs may require root. Running via root cron is typical:

- Use `sudo crontab -e`, or root’s crontab.

### 3) grep -P not supported
Some minimal environments ship grep without PCRE support. This script uses:

- `grep -P` and `grep -Pv`

If your grep lacks -P, install GNU grep with PCRE support or adjust the filtering to use ERE/awk.

### 4) Webhook/heartbeat failing
If curl is missing, the script logs a warning and continues.
If curl requests fail, it logs an error but does not abort the whole run.

### 5) Too many repeated alerts
Because the script is stateless, any matching line that remains within the lookback window can trigger again.

---

## Safety note

This script only reads logs and sends notifications. It does not attempt repairs.
If you receive BTRFS errors, treat them seriously: check filesystem health, backups, SMART, and consider a scrub or deeper investigation.
