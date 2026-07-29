# Screenshots

> **STATUS: to be captured.** This file is the index; add images to the
> directories below and tick them off.

Evidence that the lab actually runs. The repository shows the configuration; the
screenshots show it working.

## Before committing any image

Screenshots leak more than text does, and nobody reviews them. Check each one for:

- Passwords typed into a terminal or visible in a config file
- Browser tabs, taskbars, notifications and window titles unrelated to the lab
- Anything identifying that does not belong in a public repository

Text can be grepped for secrets. Images cannot, so they need an actual look.

## What to capture

### `active-directory/`

- [ ] `ipconfig /all` on CLIENT01 — DHCP server, lease, DNS suffix visible
- [ ] `Get-DhcpServerv4Lease` on DC01 showing CLIENT01's lease
- [ ] ADUC showing the `Company > {Computers, Employees, Groups}` OU structure
- [ ] `whoami /groups` on CLIENT01 showing `LAB\IT-Team` in the token
- [ ] `Get-SmbShareAccess -Name CompanyShare` — `IT-Team` only, no `Everyone`
- [ ] NTFS permissions dialog with inheritance disabled

### `monitoring/`

- [ ] Prometheus targets page, every job `up`
- [ ] Prometheus rules page, 15 rules in 3 groups
- [ ] Node Exporter Full dashboard with live data
- [ ] Windows Exporter dashboard for DC01
- [ ] InfraLab backup dashboard with real metrics
- [ ] Alertmanager UI with an alert firing
- [ ] `alert-sink.log` showing a delivered notification with its timestamp

### `backups/`

- [ ] `restic snapshots` output
- [ ] A successful `backup-dc01.sh` run
- [ ] `infralab_backup.prom` contents
- [ ] The mount-guard test: exit 1, `mount_ok 0`, previous success timestamp preserved

### `restore-tests/`

- [ ] `verify-restore.sh` reporting `Mismatch count: 0`
- [ ] The negative test showing a mismatch being caught
- [ ] Grafana panel showing time since last passing restore test

### `incidents/`

One per incident, showing the alert that detected it:

- [ ] INC-001 — DNS. Note that nothing alerted at the time; capture the probe
      working *now* instead, which is the fix
- [ ] INC-002 — `WindowsDiskSpaceLow` then `Critical` firing
- [ ] INC-003 — `BackupStale` firing, plus the alert-sink entry
- [ ] INC-004 — Kerberos failure on CLIENT01 and the matching Security event
- [ ] INC-005 — restore mismatch detected

### `architecture/`

- [ ] Virtual Network Editor showing VMnet2 with **DHCP unchecked** — this is
      the single most consequential configuration decision in the build
- [ ] Workstation library with all four VMs

## Linking them

Reference screenshots from the document they support rather than leaving them in
a folder nobody opens. An incident record with the alert that detected it is
worth considerably more than the same image filed on its own.
