# INC-005 — Restore verification detects changed backup data

> **Fields marked `_fill in_` need the real times from your session notes.**
> Everything else reflects what was actually run and observed.

| Field | Value |
|---|---|
| Date | _fill in_ |
| Detected at | _fill in_ |
| Resolved at | _fill in_ |
| Duration | _fill in_ |
| Severity | Critical |
| Affected systems | BKP01 |
| Detected by | `RestoreTestFailed` |
| Simulated | Yes, deliberate exercise, in two parts |

## Summary

Two separate tests were run. The first proved the checksum comparison logic
itself catches a real difference, without touching anything live. The second
drove an actual failing run of `verify-restore.sh` end to end, through
Alertmanager and back to resolved. **At no point was the restic repository
itself modified.**

## Detection

`RestoreTestFailed` fired when `infralab_restore_test_success` went to `0`
after the second test.

_fill in: the alert-sink log entry and the exact time it moved from `pending`
to `firing`, from `/var/log/alert-sink/alert-sink.log` on MON01._

## Timeline

| Time | Event |
|---|---|
| _fill in_ | Part 1: negative test on a disposable restore copy, no live system affected |
| _fill in_ | Part 2: extra file added to the live SMB share |
| _fill in_ | `verify-restore.sh` run, exited 1 |
| _fill in_ | `RestoreTestFailed` entered pending, then fired |
| _fill in_ | Extra file removed, fresh backup taken |
| _fill in_ | `verify-restore.sh` rerun, exited 0 |
| _fill in_ | Alert resolved |

## Method

**Part 1 — prove the comparison logic without any risk.** Restored the latest
snapshot to a temporary directory, deliberately altered one restored file
(`test1.txt`) in that copy only, then ran the same checksum comparison
`verify-restore.sh` performs by hand:

```bash
sudo -i
export RESTIC_REPOSITORY=/var/backups/restic-repo
export RESTIC_PASSWORD_FILE=/etc/restic-pass

TESTDIR=$(mktemp -d /var/tmp/infralab-negative.XXXXXX)
restic restore latest --tag dc01-share --target "$TESTDIR"
echo "corrupted" >> "$TESTDIR/mnt/dc01-share/test1.txt"

( cd /mnt/dc01-share && find . -type f -exec sha256sum {} + ) | sort -k2 > /tmp/src.sums
( cd "$TESTDIR/mnt/dc01-share" && find . -type f -exec sha256sum {} + ) | sort -k2 > /tmp/dst.sums
diff /tmp/src.sums /tmp/dst.sums | grep -c '^[<>]'
```

**Result: `2`** — one `<` line for the original checksum, one `>` for the
altered one. Confirms the comparison correctly detects a one-file difference.

**Part 2 — drive the real script and the real alert.** A new file was added to
the live SMB share after the last backup, so the most recent snapshot
legitimately did not contain it. Running `verify-restore.sh` against that state
produces a genuine mismatch, not a staged one:

```bash
sudo /usr/local/bin/verify-restore.sh
echo "exit code: $?"
cat /var/lib/prometheus/node-exporter/infralab_restore_test.prom
```

**Result:** exit code `1`, `infralab_restore_test_success 0`.
`RestoreTestFailed` progressed from pending to firing in Alertmanager.

## Safety observed

The repository was never touched in either part. Part 1 worked entirely against
a disposable restore copy in `/var/tmp`. Part 2 made the live share genuinely
diverge from the last snapshot, which is a normal, recoverable condition — not
repository corruption. This matches the safety constraint the plan for this
incident specified: damaging restic pack files directly can invalidate multiple
snapshots and is not reliably recoverable, so neither test came near the
repository's actual data.

## Root cause

Deliberately introduced in both parts. Part 1 altered a restored copy to test
the comparison. Part 2 added a file to the live share after the last backup so
the next verification would legitimately fail, which is functionally identical
to what a real backup gap would look like.

## Resolution

```bash
# Remove the extra file added to the live share, then take a fresh backup
sudo /usr/local/bin/backup-dc01.sh
sudo /usr/local/bin/verify-restore.sh
```

Result: exit `0`, alert resolved automatically once the metric reported success
again — no manual Alertmanager action needed.

## What this exercise revealed

1. **The checksum comparison correctly identifies both the count and the
   direction of a difference** — Part 1's result of exactly `2` (one removed,
   one added line) matches a single altered file precisely, not an
   approximation.
2. **A legitimate divergence between the share and the last snapshot is
   indistinguishable, from the tool's perspective, from data corruption.**
   `verify-restore.sh` cannot tell "this file changed after the backup" apart
   from "this file restored incorrectly" — both produce the same mismatch.
   This is a known limitation, already noted in the script's header: the
   comparison is against the *live* share, so anything edited since the last
   snapshot registers as a failure even though nothing is actually broken. It
   is acceptable here because the test data is static; against a genuinely
   changing dataset, a false positive of exactly this kind would need to be
   ruled out before treating every `RestoreTestFailed` as real data loss.
3. **Recovery required only a fresh backup, not any repair action** — because
   nothing was actually broken, only stale.

## Related

[`docs/backup-policy.md`](../backup-policy.md),
`scripts/linux/verify-restore.sh`
