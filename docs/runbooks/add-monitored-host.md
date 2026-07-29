# Runbook — bring a new host under monitoring

**When:** a host is added to the lab, or an existing host has been running
unmonitored.

**Time:** 15 minutes.
**Access:** root or administrator on the new host, plus root on MON01.

## 1. Install the exporter

**Linux:**

```bash
sudo apt update && sudo apt install -y prometheus-node-exporter
sudo systemctl enable --now prometheus-node-exporter
curl -s localhost:9100/metrics | head -3
```

If the host will publish custom metrics, enable the textfile collector as well:

```bash
sudo mkdir -p /var/lib/prometheus/node-exporter
sudo mkdir -p /etc/systemd/system/prometheus-node-exporter.service.d
sudo tee /etc/systemd/system/prometheus-node-exporter.service.d/textfile.conf >/dev/null <<'EOF'
[Service]
Environment=ARGS=--collector.textfile.directory=/var/lib/prometheus/node-exporter
EOF
sudo systemctl daemon-reload && sudo systemctl restart prometheus-node-exporter
```

**Windows:** confirm the service names first — the collector filter matches on
name, not display name, and a wrong name produces a filter that silently matches
nothing while everything appears healthy.

```powershell
Get-Service <names> | Format-Table Name, DisplayName, Status
```

```powershell
msiexec.exe --% /i C:\Temp\windows_exporter.msi /qn ENABLED_COLLECTORS="cpu,cs,logical_disk,memory,net,os,service,system,time"
```

## 2. Open the firewall, scoped to MON01 only

A metrics endpoint is a detailed inventory of the host. Nothing but the
collector has any reason to reach it.

```powershell
New-NetFirewallRule -DisplayName "exporter scrape" -Direction Inbound `
    -Protocol TCP -LocalPort 9182 -RemoteAddress 192.168.56.20 -Action Allow
```

```bash
# Linux, if ufw is active
sudo ufw allow from 192.168.56.20 to any port 9100 proto tcp
```

## 3. Add the target on MON01

Edit the appropriate job in `/etc/prometheus/prometheus.yml`:

```yaml
  - job_name: node
    static_configs:
      - targets: ['192.168.56.20:9100']
        labels:
          host: MON01
      - targets: ['192.168.56.40:9100']    # new host
        labels:
          host: NEWHOST
```

Set the `host` label. Alert annotations and dashboards read it, and without it a
notification says `192.168.56.40:9100` instead of a name someone recognises at
02:00.

## 4. Validate before reloading

```bash
promtool check config /etc/prometheus/prometheus.yml
```

A broken config file will stop Prometheus from starting, taking all monitoring
with it. Never skip this, and never restart before it passes.

```bash
sudo systemctl reload prometheus || sudo systemctl restart prometheus
```

## 5. Confirm the target is actually up

```bash
curl -s 'localhost:9090/api/v1/targets?state=active' |
  python3 -c 'import json,sys; [print(t["labels"].get("host","?"), t["scrapeUrl"], t["health"]) for t in json.load(sys.stdin)["data"]["activeTargets"]]'
```

The new host must show `up`. A target that appears but reports `down` is usually
the firewall rule or a wrong port.

## 6. Confirm it is alerting, not merely scraped

A scraped host with no rules matching it is not monitored, it is graphed.

```bash
# Does anything actually evaluate against this instance?
curl -s 'localhost:9090/api/v1/query?query=up{host="NEWHOST"}' |
  python3 -c 'import json,sys; print(json.load(sys.stdin)["data"]["result"])'
```

Check that the existing rules cover it. `NodeDown` and the disk rules match on
any instance, so they apply automatically. Anything host-specific needs a rule.

## 7. Update the documentation

```
docs/inventory.md    — add the host, its role, backup and monitoring status
docs/risks.md        — if it introduces a new single point of failure
```

This is the step people skip, and it is why inventories drift out of date until
nobody trusts them. A host that is monitored but not recorded is a host nobody
knows to check when it disappears.

## 8. Commit

```bash
git add monitoring/prometheus/prometheus.yml docs/inventory.md
git commit -m "Monitor NEWHOST"
```

The running config and the repository must not diverge. If MON01 is rebuilt from
this repository, an uncommitted target silently stops being monitored.
