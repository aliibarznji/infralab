# Backup policy

## Scope

| What | Backed up | How |
|---|---|---|
| `\\DC01\CompanyShare` | Yes | restic, pulled by BKP01 over a CIFS mount managed by autofs |
| DC01 system state and the AD database | **No** | VM snapshot only — see gaps |
| MON01 configuration | Yes, in Git | Provisioned from this repository |
| BKP01 restic repository | Not itself backed up | Integrity-checked on every run |
| CLIENT01 | No, deliberately | Disposable, rebuilt rather than restored |

## Flow

```
\\DC01\CompanyShare
        │  CIFS mount via autofs, credentials in /etc/dc01-creds (0600)
        ▼
BKP01: /mnt/dc01-share
        │  restic backup --tag dc01-share
        ▼
BKP01: /var/backups/restic-repo
```

### autofs, not a static fstab mount

`/mnt/dc01-share` is managed by autofs rather than a permanent `/etc/fstab`
entry. autofs mounts the share on first access and unmounts it after a period of
inactivity, remounting automatically the next time something touches the path.

This changes what "the share went away" actually means for this lab. It was
discovered during mount-guard testing: `sudo umount /mnt/dc01-share` did not
simulate a failure, because autofs simply remounted it on the very next access
— including the access the test script made to check `mountpoint`. The mount
guard could not be exercised by unmounting the share by hand.

The real failure mode autofs does *not* paper over is DC01 being unreachable.
With DC01 powered off, autofs has nothing to remount from, so the automount
fails and `/mnt/dc01-share` genuinely is not a mountpoint when the backup script
checks. That is the test actually used — see
[`docs/incidents/INC-003-stale-backup.md`](incidents/INC-003-stale-backup.md).

Backups are **pulled**, not pushed. BKP01 holds the credential and reaches into
DC01. DC01 has no credential for the repository and no route to write into it,
so a compromise or ransomware event on the file server reaches the source but
not the snapshots. A push model would hand an attacker both.

Access is restricted to the `LAB\IT-Team` group on both the share and NTFS ACLs.
The share was originally created with the Windows default of `Everyone: Full
Control`, which grants every authenticated principal complete access; that was
removed. Inheritance from `C:\` was also disabled, because the parent volume
propagates `Users: Read & Execute` and would silently have re-granted read access
to every domain user, defeating the share-level restriction.

Effective access over SMB is the intersection of share and NTFS permissions, so
both layers were tightened. Leaving NTFS at its defaults would have left the
folder over-permissive to anyone reaching it locally or through a different
share path.

## Schedule

| Job | When | Mechanism |
|---|---|---|
| `backup-dc01.sh` | Daily 02:00 | systemd timer, `Persistent=true` |
| `verify-restore.sh` | Weekly, Sunday 03:00 | systemd timer, `Persistent=true` |

Originally deployed on cron. Cron does not catch up runs missed while the host
was down, and BKP01 is shut down whenever CLIENT01 runs to stay inside the RAM
budget — so a backup scheduled in that window was skipped outright rather than
deferred. `Persistent=true` records the missed run and executes it at next boot.

## Retention

```
--keep-daily 7 --keep-weekly 4 --keep-monthly 6
```

## Integrity checking

`restic check --read-data-subset=N/7` runs after every backup, where N is the day
of the week. Repository structure is verified every run; pack data is verified
one seventh at a time, so all of it is re-read once a week without re-reading
everything daily. A full `--read-data` on every run does not scale and is not
what production systems do.

## The mount guard

The job refuses to run if `/mnt/dc01-share` is not a mountpoint, or is mounted
but empty.

This is not defensive padding. An unmounted CIFS mountpoint is simply an empty
directory. Backing it up produces a completely valid, entirely empty snapshot —
which then satisfies every freshness check, every retention rule and every
"when did the last backup succeed" question, while protecting nothing. The
failure is silent by construction, and it is the one this guard exists for.

## Verification

A backup that has never been restored is not a backup; it is a hope. The full
loop was proven by hand once — a file was deleted from `CompanyShare`, restored
from snapshot `7e7efe70`, compared, and copied back — and is now automated so it
keeps happening after everyone has stopped thinking about it.

`verify-restore.sh`, weekly:

1. Restores the latest snapshot to a temporary directory
2. Takes a SHA-256 checksum of every file in the live share
3. Takes a SHA-256 checksum of every file in the restored tree
4. Sorts and compares both lists in full
5. Publishes the result to Prometheus and cleans up

The comparison covers the **whole** restored tree. Checking one sample file
proves that one file restored.

Backup outcome and restore outcome are published as separate metrics and alerted
on separately, because a backup can complete cleanly and still be unrestorable.

## A snapshot is not a backup

VM snapshots are used to roll back incident simulations, which is the right tool
for that job. They are not backups:

- A snapshot lives on the same disk as the VM it protects. One disk failure takes
  both.
- A snapshot is a delta chain against a running disk, not an independent copy.
- Snapshots grow without bound and degrade performance. Short-lived operational
  tool, not a retention mechanism.
- A file corrupted inside the guest is faithfully preserved by the snapshot.

The restic repository is the backup. The snapshots are an undo button.

## Credential handling

| File | Purpose | Mode |
|---|---|---|
| `/etc/dc01-creds` | CIFS mount credentials | 0600, root |
| `/etc/restic-pass` | restic repository password | 0600, root |

Both are referenced by path — from the autofs map and from the script's
environment — rather than passed as arguments, so neither appears in a job
definition, the script body, or in `ps` output visible to other users.

**The restic password has no recovery path.** There is no vendor reset: losing it
makes every snapshot permanently unreadable. It is held in a password manager
outside this repository, and the exposure is recorded in `risks.md`.

## Operational notes

Snapshots created by the scheduled job are owned by root. restic commands
against those snapshots must be run with `sudo`, or they fail with permission
errors on the repository files.

## Known simplifications compared with production

Recorded plainly, because knowing where a lab diverges from production is the
point of building one.

- **Prune runs immediately after every backup.** In production, backup and prune
  are scheduled separately: prune takes exclusive locks and can run long, so
  coupling it to the backup window puts the backup itself at risk.
- **The repository is on the same physical laptop as its source.** This breaks
  3-2-1 outright. One hardware failure destroys both.
- **Retention is 7/4/6.** Short, to keep the lab small. A regulated environment
  would have retention obligations measured in years.
- **No off-site and no immutable copy.** Ransomware reaching BKP01 could delete
  the repository. Production would use append-only or object-lock storage.
- **The AD database is not backed up.** Only `CompanyShare` is protected. DC01
  itself relies on VM snapshots, which the section above explains are not
  backups. A real deployment needs Windows Server Backup system state or an
  AD-aware backup product.
