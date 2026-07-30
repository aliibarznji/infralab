# Screenshots

Evidence that the lab actually runs. The repository shows the configuration;
these show it working. Every image was reviewed before committing — screenshots
leak more than text does, and unlike text they cannot be grepped for secrets.

## architecture/

| Image | Shows |
|---|---|
| [01-vmnet2-dhcp-disabled.png](architecture/01-vmnet2-dhcp-disabled.png) | Virtual Network Editor: DHCP disabled on VMnet2 while VMware's other networks still have it enabled — the single most consequential configuration decision in the build |
| [02-vm-library.png](architecture/02-vm-library.png) | All four VMs in VMware Workstation Pro 26H1 |

## active-directory/

| Image | Shows |
|---|---|
| [01-dhcp-lease-client.png](active-directory/01-dhcp-lease-client.png) | `ipconfig /all` on CLIENT01: lease from DC01, suffix `lab.local`, address .101. NetBIOS over Tcpip enabled — the mechanism behind INC-001's masking finding |
| [02-dhcp-lease-server.png](active-directory/02-dhcp-lease-server.png) | `Get-DhcpServerv4Lease` on DC01, the same lease seen server-side |
| [03-ou-structure.png](active-directory/03-ou-structure.png) | ADUC: `Company > {Computers, Employees, Groups}` |
| [04-token-groups.png](active-directory/04-token-groups.png) | `whoami /groups` with `LAB\IT-Team` in the token — the ACL is effective, not just configured |
| [05-share-acl.png](active-directory/05-share-acl.png) | `Get-SmbShareAccess`: IT-Team is the only entry; Everyone genuinely removed |
| [06-ntfs-inheritance.png](active-directory/06-ntfs-inheritance.png) | Advanced Security dialog: inheritance disabled, every ACE `Inherited from: None` — direct proof of the CHANGE-004 inheritance trap |

## monitoring/

| Image | Shows |
|---|---|
| [01-targets-up.png](monitoring/01-targets-up.png) | Prometheus targets: all six scrape groups up |
| [02-rules.png](monitoring/02-rules.png) | Rules page: backup group's 7 rules OK, including ClockSkewHigh from INC-004 |
| [03-node-dashboard.png](monitoring/03-node-dashboard.png) | Node Exporter Full with live BKP01 data |
| [04-windows-dashboard.png](monitoring/04-windows-dashboard.png) | Windows exporter dashboard — disk, bandwidth and NTP panels live; several panels N/A from a known metric-name mismatch, kept honest rather than edited out |
| [05-backup-dashboard.png](monitoring/05-backup-dashboard.png) | InfraLab backup dashboard, all six panels green — after fixing two panels that queried never-deployed metrics |
| [06-alertmanager.png](monitoring/06-alertmanager.png) | `amtool alert` — the Debian package ships no web UI, only the API |
| [07-alert-sink-log.png](monitoring/07-alert-sink-log.png) | The delivery log capturing INC-002, INC-003 and INC-005 firing and resolving live — the source of the timestamps in those incident records |

## backups/

| Image | Shows |
|---|---|
| [01-snapshots.png](backups/01-snapshots.png) | `restic snapshots`: all snapshots targeting `/mnt/dc01-share` — captured after the stray `/etc` snapshot cleanup recorded in `docs/risks.md` |
| [02-backup-run.png](backups/02-backup-run.png) | Full `backup-dc01.sh` run: backup, retention, integrity check, success |
| [03-metrics.png](backups/03-metrics.png) | `infralab_backup.prom`: exit_code 0, mount_ok 1, timestamps live |
| [04-timers.png](backups/04-timers.png) | Both `infralab-*` systemd timers scheduled with sensible next-run times |

## restore-tests/

| Image | Shows |
|---|---|
| [01-verify-pass-metrics.png](restore-tests/01-verify-pass-metrics.png) | `infralab_restore_test.prom`: success 1, mismatches 0 — the automated restore verification passing |

## Not captured, deliberately

Alerts firing *during* the incident exercises were not re-staged for photos —
re-running an incident purely to photograph it would make the record
performative. The alert-sink log (`monitoring/07-alert-sink-log.png`) carries
that evidence instead, with real timestamps.
