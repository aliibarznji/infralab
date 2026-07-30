# INC-003 — Backup stops when DC01 is unreachable, and recovers cleanly

> **Fields marked `_fill in_` need the real values from your session** — exact
> times and the alert-sink log lines. Everything else below reflects what was
> actually run and observed.

| Field | Value |
|---|---|
| Date | _fill in_ |
| Detected at | _fill in_ |
| Resolved at | _fill in_ |
| Duration | _fill in_ |
| Severity | Critical |
| Affected systems | BKP01 (backup path), DC01 (powered off for the test) |
| Detected by | `backup-dc01.sh` mount guard, exit code and metrics |
| Simulated | Yes, deliberate exercise — method changed from the original plan, see below |

## Summary

The planned method for this exercise was to `umount /mnt/dc01-share` by hand and
run the backup job against the unmounted path. That did not work: `/mnt/dc01-share`
is managed by **autofs**, not a static `/etc/fstab` mount, and autofs remounted
the share on the very next access — including the access the backup script
itself made to check `mountpoint`. Unmounting by hand could not produce a
failure.

DC01 was powered off instead. With no host to mount from, autofs's automount
genuinely failed, and `backup-dc01.sh`'s mount guard correctly detected that
`/mnt/dc01-share` was not a mountpoint and refused to run. DC01 was then powered
back on and the backup ran successfully on the next attempt, confirming both the
failure detection and the recovery path.

## Detection

`backup-dc01.sh`'s own mount guard — `mountpoint -q "$SHARE_MOUNT"` — is what
caught this, not an external monitor. The guard exists specifically because an
unmounted mountpoint is an empty directory, and backing that up produces a
valid, empty snapshot that would satisfy every downstream freshness check while
protecting nothing.

_fill in: did `BackupFailed` or `BackupMountMissing` also fire in Alertmanager
during this test? Check `/var/log/alert-sink/alert-sink.log` on MON01 for the
delivery and note the alert name and timestamp here._

## Timeline

| Time | Event |
|---|---|
| _fill in_ | Attempted `sudo umount /mnt/dc01-share` |
| _fill in_ | Ran `backup-dc01.sh` — succeeded anyway; discovered autofs had remounted the share |
| _fill in_ | DC01 powered off |
| _fill in_ | Ran `backup-dc01.sh` — failed as expected |
| _fill in_ | Alert fired (if applicable) |
| _fill in_ | DC01 powered back on |
| _fill in_ | Ran `backup-dc01.sh` — succeeded |
| _fill in_ | Alert resolved (if applicable) |

## Investigation

| Test | Result | What it showed |
|---|---|---|
| `sudo umount /mnt/dc01-share` then run backup | Backup succeeded | autofs had already remounted the share before the script's mount check ran |
| Check the automount configuration | autofs manages `/mnt/dc01-share`, not `/etc/fstab` | Explains why a manual unmount is not a valid failure simulation on this host |
| Power off DC01, run backup | `ERROR: /mnt/dc01-share is not mounted`, exit 1 | autofs cannot remount from an unreachable host — this is a real failure, not a simulated one |
| Check `infralab_backup.prom` after the failed run | `infralab_backup_last_run_exit_code 1`, `infralab_backup_mount_ok 0`, previous `last_success_timestamp` unchanged | Metrics still published on failure; the prior success timestamp was not cleared |
| Power DC01 back on, run backup | `Backup completed successfully`, `exit_code 0`, `mount_ok 1`, `snapshot_count 5` | Recovery is automatic — no manual remount or script intervention needed once DC01 answers again |

## Root cause

Not a fault in the traditional sense — DC01 being off is the deliberately
introduced condition. The finding is architectural: **autofs made the intended
test method (a manual unmount) invalid**, because it treats an unmounted path as
something to transparently remount rather than as a persistent failure. The only
way to produce a genuine, sustained mount failure against an autofs-managed path
is to remove the thing autofs mounts *from* — i.e., make the source host
unreachable.

## Resolution

Power DC01 back on. No script or configuration change was needed; the next
scheduled or manual backup run succeeded once the automount could reach DC01
again.

## Prevention / what already covers this

| Measure | How it applies here |
|---|---|
| Mount guard in `backup-dc01.sh` | Refused to run rather than backing up an empty path |
| Metrics published on failure | `exit_code`, `mount_ok` and the unchanged `last_success_timestamp` were all correct and visible |
| `BackupMountMissing` / `BackupFailed` alert rules | _fill in: confirm these fired_ |
| `NodeDown` / `ICMPProbeFailed` on DC01 | Would independently show DC01 itself down, giving the actual root cause alongside the backup symptom |

## What this exercise revealed

1. **The planned test method was wrong for this environment**, and finding that
   out was itself useful. A runbook or incident plan that assumes a specific
   mount mechanism needs to say which one, because "unmount the share" means
   different things under a static fstab mount versus autofs.
2. **autofs changes the failure model.** A share mounted through autofs
   recovers from a transient disruption automatically and silently, which is
   good for availability but means "the mount disappeared" is not, by itself, a
   reliable way to detect that DC01 has a problem. The backup guard still works
   correctly — it just triggers on host unavailability rather than on mount
   state directly.
3. **Recovery required no operator action.** Once DC01 came back, the very
   next backup attempt succeeded without remounting anything by hand. That is
   the intended behaviour of pairing autofs with `Persistent=true` timers: a
   missed window catches up automatically at the next opportunity.

## Related

- [`docs/backup-policy.md`](../backup-policy.md) — autofs design note
- [`docs/risks.md`](../risks.md)
- `scripts/linux/backup-dc01.sh` — the mount guard this exercise validated
