# Runbook — disk space low or exhausted

**When:** `DiskSpaceLow`, `DiskSpaceCritical`, `WindowsDiskSpaceLow` or
`WindowsDiskSpaceCritical` fires, or `health-check.sh` reports the root
filesystem above 80%.

**Time:** 10–30 minutes.
**Access:** root on the Linux host, or administrator on DC01.

A full system volume on a domain controller can damage the AD database. Treat a
critical alert on DC01 as urgent rather than routine housekeeping.

## 1. Find out which volume, and how fast

```bash
# Linux
df -h
```

```powershell
# Windows
Get-CimInstance Win32_LogicalDisk -Filter 'DriveType = 3' |
    Select-Object DeviceID,
        @{n='FreeGB';e={[math]::Round($_.FreeSpace/1GB,2)}},
        @{n='SizeGB';e={[math]::Round($_.Size/1GB,2)}}
```

Then check the trend in Grafana before deleting anything. A volume that has been
at 87% for three months is a capacity planning conversation. One that went from
40% to 87% overnight is an incident, and deleting files without finding the cause
means it fills again.

## 2. Find what is consuming the space

```bash
# Linux — largest directories, then largest files
sudo du -xh --max-depth=2 / 2>/dev/null | sort -rh | head -20
sudo find / -xdev -type f -size +100M -exec ls -lh {} + 2>/dev/null | sort -k5 -rh | head -20

# Deleted files still held open by a process: space that df sees as used but
# du cannot find. A common cause of a confusing discrepancy.
sudo lsof +L1 2>/dev/null | head -20
```

```powershell
# Windows — largest folders under a path
Get-ChildItem C:\ -Directory |
    ForEach-Object {
        $size = (Get-ChildItem $_.FullName -Recurse -File -ErrorAction SilentlyContinue |
                 Measure-Object Length -Sum).Sum
        [pscustomobject]@{ Path = $_.FullName; GB = [math]::Round($size/1GB, 2) }
    } | Sort-Object GB -Descending | Select-Object -First 15
```

## 3. Reclaim, in order of safety

**Linux, safe:**

```bash
sudo journalctl --disk-usage
sudo journalctl --vacuum-time=14d
sudo apt clean
sudo apt autoremove --purge
```

**BKP01 specifically** — check for abandoned staged restores before anything
else. `verify-restore.sh` cleans up after itself via a trap, but an interrupted
manual restore does not:

```bash
ls -la /var/tmp/ | grep -E 'infralab-restore|restore\.'
sudo du -sh /var/backups/restic-repo
```

Do **not** delete anything inside the restic repository by hand. Use retention:

```bash
sudo -i
export RESTIC_REPOSITORY=/var/backups/restic-repo
export RESTIC_PASSWORD_FILE=/etc/restic-pass
restic forget --tag dc01-share --keep-daily 7 --keep-weekly 4 --keep-monthly 6 --prune
```

**Windows, safe:**

- `C:\Windows\Temp` and `%TEMP%`
- Old health check reports in `C:\HealthChecks`
- `Cleanup-Image /StartComponentCleanup` for the WinSxS store
- IIS or application logs, if any

**Windows, never without understanding the consequence:**

- `C:\Windows\NTDS` — the AD database
- `C:\Windows\SYSVOL` — replicated policy and scripts
- Anything under `C:\Windows\System32` other than known log directories

## 4. Verify

```bash
df -h /
```

Confirm the alert clears in Prometheus rather than assuming it did:

```bash
curl -s localhost:9090/api/v1/alerts |
  python3 -c 'import json,sys; print([a["labels"]["alertname"] for a in json.load(sys.stdin)["data"]["alerts"]] or "none firing")'
```

## 5. Address the cause

Reclaiming space is not the fix. Answer why it filled:

- Log rotation not configured, or configured but not running
- A process writing without bound
- Backup retention not pruning
- The volume genuinely undersized for its workload

If it is the last one, that is a capacity finding and belongs in
`docs/risks.md`, not in a cleanup script run repeatedly.

## Notes

The 85% warning threshold exists to leave room to act. If alerts arrive
routinely and are cleared by routine cleanup, either the threshold is wrong for
that volume or the volume is too small. Both are worth fixing — an alert that
fires predictably and is always dismissed trains people to dismiss alerts.
