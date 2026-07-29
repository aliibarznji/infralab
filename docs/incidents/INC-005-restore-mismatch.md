# INC-005 — Restore verification detects changed backup data

> **STATUS: PLANNED — not yet performed.** This is the pre-flight plan. Replace
> this banner with the real record once the exercise has run, using
> [`TEMPLATE.md`](TEMPLATE.md) for the section order.

| Field | Value |
|---|---|
| Date | _to be recorded_ |
| Severity | Critical |
| Affected systems | BKP01 |
| Expected detection | `RestoreTestFailed` |
| Simulated | Yes |

## Safety — do not corrupt the real repository

The obvious way to test this is to damage a restic pack file. **Do not.**
Repository corruption can invalidate many snapshots at once, is not reliably
recoverable, and would destroy the only backup of `CompanyShare`.

Modifying the *restored output* before comparison exercises exactly the same
detection path — the checksum comparison in `verify-restore.sh` — at zero risk.
The script cannot tell the difference between a file that restored wrong and a
file that was altered after restoring, which is precisely why this works as a
test of the detection logic.

If a genuine repository-corruption exercise is ever wanted, it runs against a
disposable copy made with `restic copy` to a second repository, and the record
must say so explicitly.

## Method

```bash
sudo -i
export RESTIC_REPOSITORY=/var/backups/restic-repo
export RESTIC_PASSWORD_FILE=/etc/restic-pass

TESTDIR=$(mktemp -d /var/tmp/infralab-negative.XXXXXX)
restic restore latest --tag dc01-share --target "$TESTDIR"

# Break exactly one restored file. Adjust the path to a file that exists.
ls "$TESTDIR/mnt/dc01-share/"
echo "corrupted" >> "$TESTDIR/mnt/dc01-share/<pick-a-file>"

# The same comparison verify-restore.sh performs.
( cd /mnt/dc01-share && find . -type f -exec sha256sum {} + ) | sort -k2 > /tmp/src.sums
( cd "$TESTDIR/mnt/dc01-share" && find . -type f -exec sha256sum {} + ) | sort -k2 > /tmp/dst.sums
diff /tmp/src.sums /tmp/dst.sums
diff /tmp/src.sums /tmp/dst.sums | grep -c '^[<>]'

rm -rf "$TESTDIR" /tmp/src.sums /tmp/dst.sums
exit
```

Expected: a mismatch count of `2` — one `<` line for the original checksum and
one `>` line for the altered one.

## Driving the alert end to end

The block above proves the comparison logic. To see the alert actually fire,
make `verify-restore.sh` itself fail. The least invasive way is to add a file to
the live share that is not in the snapshot, so the restored tree legitimately
differs:

```bash
# On DC01, or from a client with write access:
#   create a new file in CompanyShare, then immediately:
sudo /usr/local/bin/verify-restore.sh ; echo "exit code $?"
cat /var/lib/prometheus/node-exporter/infralab_restore_test.prom
```

Expected: non-zero exit, `infralab_restore_test_success 0`, a non-zero mismatch
count, **and the previous success timestamp preserved**. `RestoreTestFailed`
fires after 5 minutes.

This also demonstrates a real property of the check worth writing up: comparing
a restore against a *live* share means legitimate changes since the snapshot
register as mismatches. In this lab the data is static so any difference is a
genuine fault, but the limitation is real and is noted in the script's header.

## What to record

- Mismatch count and the diff output
- Metric values before and after
- Time from failure to `RestoreTestFailed` firing, and the alert-sink entry
- Whether `BackupStale` and `BackupFailed` correctly stayed quiet — the point of
  tracking backup and restore separately is that one can fail while the other is
  healthy

## Resolution

```bash
# Remove the extra file from the share, or take a fresh backup so the snapshot
# matches the share again.
sudo /usr/local/bin/backup-dc01.sh
sudo /usr/local/bin/verify-restore.sh
```

## Questions the writeup should answer

- Would a real restore failure have been noticed without this check?
- Is weekly often enough? What is the worst case between a backup silently
  becoming unrestorable and the test discovering it?
- Should the comparison run against a second restore of the same snapshot rather
  than the live share, to remove the false-positive class demonstrated here?

## Related

[`docs/backup-policy.md`](../backup-policy.md), `scripts/linux/verify-restore.sh`
