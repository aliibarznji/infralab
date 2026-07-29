# Runbook — deploy alerting, blackbox probes and backup metrics

Brings the repository's monitoring configuration onto the running hosts. Written
for the native systemd deployment, not containers.

**Order matters.** BKP01's textfile collector must exist before the backup
scripts write to it, and windows_exporter must be scraping before its alert
rules mean anything.

| Step | Host | What |
|---|---|---|
| 0 | Windows host | Copy files to MON01 and BKP01 |
| 1 | BKP01 | node_exporter + textfile collector |
| 2 | DC01 | windows_exporter |
| 3 | MON01 | Alertmanager, blackbox exporter, alert-sink, rules |
| 4 | BKP01 | Backup and restore-verification scripts, on cron |
| 5 | BKP01 | Convert cron to systemd timers |

Replace `ali@` with your actual SSH user throughout.

---

## Step 0 — copy files out (run on the Windows host)

```powershell
$repo = 'C:\Users\aliib\Desktop\infrastructure'
scp -r "$repo\monitoring" ali@192.168.56.20:/tmp/
scp "$repo\scripts\linux\alert-sink.py" ali@192.168.56.20:/tmp/
scp "$repo\scripts\linux\systemd\infralab-alert-sink.service" ali@192.168.56.20:/tmp/
scp "$repo\scripts\linux\backup-dc01.sh" "$repo\scripts\linux\verify-restore.sh" ali@192.168.56.30:/tmp/
```

---

## Step 1 — BKP01: node_exporter and the textfile collector

This directory is the entire channel by which backup results reach monitoring.
If it is wrong, the scripts will appear to work while publishing nothing, so the
block ends by proving the channel end to end.

```bash
sudo apt update && sudo apt install -y prometheus-node-exporter

sudo mkdir -p /var/lib/prometheus/node-exporter /var/lib/infralab
sudo chmod 0755 /var/lib/prometheus/node-exporter

# Drop-in rather than editing the packaged unit, so a package upgrade cannot
# silently revert it.
sudo mkdir -p /etc/systemd/system/prometheus-node-exporter.service.d
sudo tee /etc/systemd/system/prometheus-node-exporter.service.d/textfile.conf >/dev/null <<'EOF'
[Service]
Environment=ARGS=--collector.textfile.directory=/var/lib/prometheus/node-exporter
EOF

sudo systemctl daemon-reload
sudo systemctl enable --now prometheus-node-exporter
sudo systemctl restart prometheus-node-exporter

# Prove the textfile channel works: write a probe metric, confirm node_exporter
# serves it, then remove it.
echo 'infralab_deploy_probe 1' | sudo tee /var/lib/prometheus/node-exporter/probe.prom >/dev/null
sleep 2
curl -s localhost:9100/metrics | grep infralab_deploy_probe \
  && echo "TEXTFILE COLLECTOR OK" \
  || echo "TEXTFILE COLLECTOR NOT WORKING - stop here and fix"
sudo rm -f /var/lib/prometheus/node-exporter/probe.prom
```

Expected: `infralab_deploy_probe 1` then `TEXTFILE COLLECTOR OK`.

---

## Step 2 — DC01: windows_exporter

Console only, so the commands are kept short.

Get the MSI onto the machine first — drag and drop from the host, or reconnect
the NAT adapter briefly and download it, then disconnect again.

**2a. Confirm the service names before configuring anything.** Names differ from
display names, and the collector filter matches on the name. A wrong name gives
a filter that silently matches nothing: the exporter comes up healthy, the
scrape succeeds, and no service is actually watched.

```powershell
Get-Service NTDS,DNS,DHCPServer,Netlogon | Format-Table Name,DisplayName,Status
```

**2b. Install.** `--%` stops PowerShell parsing the rest of the line, so the
pipes in the filter reach msiexec intact.

```powershell
msiexec.exe --% /i C:\Temp\windows_exporter.msi /qn ENABLED_COLLECTORS="cpu,cs,logical_disk,memory,net,os,service,system,time,ad,dns" EXTRA_FLAGS="--collector.service.include=NTDS|DNS|DHCPServer|Netlogon"
```

**2c. Firewall, scoped to MON01 only.** A metrics endpoint is a detailed
inventory of the host; nothing but the collector needs to reach it.

```powershell
New-NetFirewallRule -DisplayName "windows_exporter" -Direction Inbound -Protocol TCP -LocalPort 9182 -RemoteAddress 192.168.56.20 -Action Allow
```

**2d. Verify.**

```powershell
Get-Service windows_exporter | Format-Table Name,Status,StartType
(irm http://localhost:9182/metrics) -split "`n" | Select-String '^windows_service_state' | Select-Object -First 8
```

Expected: service `Running` and `Automatic`, and exactly four services listed,
each with one `state=` line valued `1`.

---

## Step 3 — MON01: Alertmanager, blackbox, alert-sink, rules

```bash
sudo apt update && sudo apt install -y prometheus-alertmanager prometheus-blackbox-exporter

# Find where this Prometheus reads its config from, rather than assuming.
systemctl cat prometheus | grep -E 'ExecStart|config.file'
```

Note the `--config.file` path from that output. The block below assumes the
Debian layout, `/etc/prometheus`. Adjust if yours differs.

```bash
sudo cp /tmp/monitoring/prometheus/prometheus.yml /etc/prometheus/prometheus.yml
sudo cp /tmp/monitoring/prometheus/alerts.yml     /etc/prometheus/alerts.yml
sudo cp /tmp/monitoring/blackbox/blackbox.yml     /etc/prometheus/blackbox.yml
sudo cp /tmp/monitoring/alertmanager/alertmanager.yml /etc/prometheus/alertmanager.yml

# alert-sink: a stdlib-only webhook receiver that logs every notification with
# its firing time. Alertmanager's UI shows what is firing now; an incident
# record needs what fired and when.
sudo cp /tmp/alert-sink.py /usr/local/bin/alert-sink.py
sudo chmod 0755 /usr/local/bin/alert-sink.py
sudo cp /tmp/infralab-alert-sink.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now infralab-alert-sink

# Validate before reloading. A bad rules file will stop Prometheus from starting.
promtool check config /etc/prometheus/prometheus.yml
```

Only if that reports SUCCESS:

```bash
sudo systemctl enable --now prometheus-blackbox-exporter prometheus-alertmanager
sudo systemctl reload prometheus || sudo systemctl restart prometheus
```

**Verify.**

```bash
# alert-sink answers
curl -s localhost:9094/ ; echo

# blackbox actually resolves the zone, not merely reaches port 53
curl -s 'localhost:9115/probe?target=192.168.56.10&module=dns_soa' | grep '^probe_success'

# every target up
curl -s 'localhost:9090/api/v1/targets?state=active' \
  | python3 -c 'import json,sys; [print(t["labels"]["job"], t["scrapeUrl"], t["health"]) for t in json.load(sys.stdin)["data"]["activeTargets"]]'

# rules loaded
curl -s localhost:9090/api/v1/rules \
  | python3 -c 'import json,sys; g=json.load(sys.stdin)["data"]["groups"]; print(sum(len(x["rules"]) for x in g), "rules in", len(g), "groups")'

# alertmanager reachable from prometheus
curl -s localhost:9093/-/healthy ; echo
```

Expected: `probe_success 1`, every target `up`, and `15 rules in 3 groups`.

`BackupStale` and `RestoreTestStale` will be firing at this point — their metrics
do not exist until Step 4. An alert firing because the thing it watches is
absent is correct behaviour, not a fault.

---

## Step 4 — BKP01: backup and restore verification on cron

```bash
sudo cp /tmp/backup-dc01.sh /usr/local/bin/backup-dc01.sh
sudo cp /tmp/verify-restore.sh /usr/local/bin/verify-restore.sh
sudo chmod 0755 /usr/local/bin/backup-dc01.sh /usr/local/bin/verify-restore.sh

# Run the backup by hand first. Never wait for a scheduled run to find out
# whether a script works.
sudo /usr/local/bin/backup-dc01.sh
cat /var/lib/prometheus/node-exporter/infralab_backup.prom
```

Expected: `Backup completed successfully`, and a metrics file with
`infralab_backup_last_run_exit_code 0`, a non-zero last-success timestamp, a
snapshot count, and `infralab_backup_mount_ok 1`.

**Prove the mount guard works.** This is the most valuable test in the backup
path: an unmounted CIFS mountpoint is an empty directory, and without the guard
the job would back up nothing and report success.

```bash
sudo umount /mnt/dc01-share
sudo /usr/local/bin/backup-dc01.sh ; echo "exit code $?"
grep -E 'exit_code|mount_ok|last_success' /var/lib/prometheus/node-exporter/infralab_backup.prom
sudo mount -a
```

Expected: `ERROR: /mnt/dc01-share is not mounted`, exit code 1,
`infralab_backup_last_run_exit_code 1`, `infralab_backup_mount_ok 0`, **and the
previous success timestamp still present** rather than cleared. Confirm no new
snapshot was created.

```bash
# Restore verification
sudo /usr/local/bin/verify-restore.sh
cat /var/lib/prometheus/node-exporter/infralab_restore_test.prom
```

Expected: `Restore verification successful`, `Mismatch count: 0`, and a files-checked
count matching what is in the share.

**Schedule.**

```bash
sudo crontab -l 2>/dev/null > /tmp/ct
grep -v 'backup-dc01\|verify-restore' /tmp/ct > /tmp/ct.new
cat >> /tmp/ct.new <<'EOF'
0 2 * * * /usr/local/bin/backup-dc01.sh >> /var/log/backup-dc01.log 2>&1
0 3 * * 0 /usr/local/bin/verify-restore.sh >> /var/log/verify-restore.log 2>&1
EOF
sudo crontab /tmp/ct.new
sudo crontab -l
```

Back on MON01, confirm the alerts have cleared:

```bash
curl -s localhost:9090/api/v1/alerts \
  | python3 -c 'import json,sys; a=json.load(sys.stdin)["data"]["alerts"]; print([x["labels"]["alertname"] for x in a] or "no alerts firing")'
```

---

## Step 5 — convert cron to systemd timers

Done as a separate step so the fix is a distinct change with its own record,
rather than being buried inside the initial deployment.

**Why.** Cron does not catch up runs missed while the host was down. BKP01 is
shut down whenever CLIENT01 runs, so a backup scheduled in that window is
skipped entirely rather than deferred. `Persistent=true` runs the job at next
boot instead.

```bash
sudo cp /tmp/systemd/infralab-*.service /tmp/systemd/infralab-*.timer /etc/systemd/system/
sudo systemctl daemon-reload

# Remove the cron entries first, or both schedulers will run the job.
sudo crontab -l | grep -v 'backup-dc01\|verify-restore' | sudo crontab -
sudo crontab -l

sudo systemctl enable --now infralab-backup.timer infralab-restore-test.timer
systemctl list-timers 'infralab-*'
```

Expected: both timers listed with a sensible next-run time, and no backup lines
left in the crontab.

**Prove the catch-up behaviour**, since it is the entire reason for the change:

```bash
# Note the last run, power the VM off for longer than the interval, boot it, and
# confirm the job ran on boot rather than being skipped.
systemctl show infralab-backup.timer -p LastTriggerUSec
journalctl -u infralab-backup.service --since '-1 day' | tail -20
```
