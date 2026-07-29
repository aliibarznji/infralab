# Runbook — restore a single file

**When:** a user reports a file on `CompanyShare` deleted or damaged and wants a
previous version back.

**Time:** about 5 minutes.
**Access:** root on BKP01; write access to the share to put the file back.

## 1. Establish what is actually being asked for

Before touching the repository, get the full path, and roughly when the file was
last known good. "It was there yesterday" and "it was there last week" restore
from different snapshots.

## 2. Find a snapshot that still has it

```bash
sudo -i
export RESTIC_REPOSITORY=/var/backups/restic-repo
export RESTIC_PASSWORD_FILE=/etc/restic-pass

restic snapshots --tag dc01-share
```

If the timing is unclear, search the file's history directly:

```bash
restic find --tag dc01-share 'filename.txt'
```

Pick the most recent snapshot from **before** the file was lost.

## 3. Restore to a staging directory, never over the live share

```bash
STAGE=$(mktemp -d /var/tmp/restore.XXXXXX)
restic restore <SNAPSHOT_ID> \
    --target "$STAGE" \
    --include '/mnt/dc01-share/path/to/filename.txt'

find "$STAGE" -type f
```

Restoring directly over the share risks overwriting something the user has
edited since, which turns one lost file into two.

## 4. Verify before handing it back

```bash
cat "$STAGE/mnt/dc01-share/path/to/filename.txt"
sha256sum "$STAGE/mnt/dc01-share/path/to/filename.txt"
```

Confirm with the requester that this is the version they expect **before**
putting it back.

## 5. Copy it into place

BKP01's mount is read-only by design, so the copy is driven from DC01 or from a
client with write access — not from the backup host. From DC01, having copied
the staged file across:

```powershell
Copy-Item 'C:\Temp\filename.txt' 'C:\CompanyShare\path\to\' -Confirm
```

Requires membership of `LAB\IT-Team`.

## 6. Clean up

```bash
rm -rf "$STAGE"
exit
```

Leaving staged restores in `/var/tmp` on the backup host is how a disk fills.

## 7. Record it

If the file was lost through a fault, open an incident record. If it was user
error, no incident is needed — but note the request. Repeated requests from the
same area usually point at a missing permission or a gap in how something was
explained, not at carelessness.

## Notes

Snapshots created by the scheduled job are owned by root. restic commands
against them must run with `sudo`, or they fail with permission errors on the
repository files rather than anything that names the real problem.
