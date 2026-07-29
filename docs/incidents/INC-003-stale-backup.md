# INC-003 — Backup silently stops

> **STATUS: PLANNED — not yet performed.** This is the pre-flight plan. Replace
> this banner with the real record once the exercise has run, using
> [`TEMPLATE.md`](TEMPLATE.md) for the section order.

| Field | Value |
|---|---|
| Date | _to be recorded_ |
| Severity | Critical |
| Affected systems | BKP01 |
| Expected detection | `BackupStale`, or `BackupMountMissing` depending on the variant |
| Simulated | Yes |

## Why this one matters most

Every other failure in this lab announces itself. A backup that stops running
announces nothing at all: the repository is still there, the last snapshot still
restores, and everything looks correct right up until someone needs a file from
after the job stopped. It is the failure mode that most justifies having
monitoring in the first place.

## Variants

Run at least the first. The second and third exercise different alerts and are
worth doing if time allows.

| Variant | Method | Expected alert |
|---|---|---|
| Scheduler stopped | `sudo systemctl disable --now infralab-backup.timer` | `BackupStale` |
| Mount broken | `sudo umount /mnt/dc01-share` then run the job | `BackupMountMissing`, `BackupFailed` |
| Credentials invalid | Change the password in `/etc/dc01-creds`, remount | `BackupMountMissing` |

Restore `/etc/dc01-creds` from a copy afterwards if running the third.

## The threshold problem

`BackupStale` fires at 25 hours. Waiting 25 hours for a demonstration is not
practical, so add a temporary parallel rule and **show both**:

```yaml
      - alert: BackupStaleDemo
        expr: time() - infralab_backup_last_success_timestamp_seconds > 300
        for: 1m
        labels:
          severity: critical
        annotations:
          summary: "DEMO RULE - no successful backup on {{ $labels.instance }} in over 5 minutes"
          description: "Temporary rule used to demonstrate the stale-backup alert path within a single session. The production threshold is 25 hours; this exists only so the alert can be observed firing."
```

```bash
sudo systemctl reload prometheus
```

**Remove it afterwards and record that you did.** A five-minute staleness
threshold left in place would fire constantly, and an alert that always fires
teaches people to ignore alerts — which is worse than having no alert.

## What to record

- Time the timer was disabled versus time `BackupStaleDemo` fired
- The alert-sink log entry showing delivery
- Whether `infralab_backup_last_success_timestamp_seconds` kept its previous
  value rather than disappearing — this is the specific design decision being
  tested, since a metric that vanishes never triggers a threshold comparison
- What Grafana's "time since last successful backup" panel showed

## Resolution

```bash
sudo systemctl enable --now infralab-backup.timer
sudo /usr/local/bin/backup-dc01.sh
systemctl list-timers 'infralab-*'
```

Confirm the alert resolves, then remove the demo rule and reload.

## Questions the writeup should answer

- How long would this have gone unnoticed without the alert?
- Is 25 hours the right threshold given BKP01 is deliberately powered off while
  CLIENT01 runs? Does `Persistent=true` on the timer actually close that gap, or
  does a long shutdown still produce a false positive?
- Does anything alert if the *metrics* stop arriving while the host stays up —
  for example if node_exporter's textfile directory became unwritable?

## Related

[`docs/backup-policy.md`](../backup-policy.md), [`docs/risks.md`](../risks.md)
