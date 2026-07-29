# CHANGE-003 — Enable backups of CompanyShare

| Field | Value |
|---|---|
| Date | _to be recorded_ |
| Implemented by | Ali |
| Category | Standard |
| Risk | Low to DC01 — read access only |
| Affected systems | BKP01, read access to DC01 |
| Downtime | None |

## Reason

`CompanyShare` held the only non-reproducible data in the lab and had no
protection of any kind.

## What changed

1. Built BKP01 on Ubuntu 26.04, static `192.168.56.30`.
2. Installed restic 0.18.1; initialised the repository at
   `/var/backups/restic-repo`.
3. Mounted `\\DC01\CompanyShare` over CIFS at `/mnt/dc01-share` via `/etc/fstab`,
   credentials in `/etc/dc01-creds` (0600, root).
4. Repository password in `/etc/restic-pass` (0600, root).
5. `/usr/local/bin/backup-dc01.sh` scheduled daily at 02:00 via cron.

Both credential files are referenced by path rather than passed as arguments, so
neither appears in the crontab, the script body, or `ps` output.

Backups are **pulled**: BKP01 reaches into DC01, and DC01 holds no credential
for the repository. A compromise of the file server reaches the source but not
the snapshots.

## Risk assessment

| Risk | Mitigation |
|---|---|
| Loss of the restic password makes every snapshot unreadable | Stored in a password manager outside the repository. No vendor reset exists — recorded in `risks.md` |
| Backup repository on the same physical host as its source | Accepted, documented; breaks 3-2-1 |
| Backup account over-privileged | Access restricted to `IT-Team` in CHANGE-004 |
| An unmounted share backs up as an empty snapshot | Not addressed here — closed by CHANGE-005 |

## Rollback

Remove the cron entry, unmount the share, delete `/etc/dc01-creds` and
`/etc/restic-pass`. DC01 is untouched throughout.

## Verification

A backup that has never been restored is not a backup. The full loop was tested:

1. Deleted `test1.txt` from `CompanyShare` on DC01
2. Restored snapshot `7e7efe70` to `/tmp/restore-test` on BKP01
3. Verified the restored contents matched
4. Copied the file back to the live share
5. Confirmed it reappeared on DC01

## Outcome

Completed. Two gaps remained and were closed later: the restore test was manual
and one-off rather than scheduled, and a backup failure was invisible to
monitoring. Both closed by CHANGE-005.
