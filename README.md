# Mini Datacenter Infrastructure Lab

> This is an independent personal learning project created to demonstrate infrastructure engineering skills. It is not affiliated with, endorsed by, or produced by any company or organization. No real company systems, data, branding, or logos are used.

A small, fully documented datacenter built on a laptop: a Windows Server domain,
a Prometheus and Grafana monitoring stack, and restic backups that are restored
and checksum-verified on a schedule rather than assumed to work.

The lab runs on VMware Workstation. This repository is the part that travels —
the automation, the configuration, the operational documentation, and the
incident record.

## What is in here

| Area | Where |
|---|---|
| Architecture, network and domain design | `docs/architecture.md` |
| Asset inventory | `docs/inventory.md` |
| Monitoring and alerting policy | `docs/monitoring-policy.md` |
| Backup and restore policy | `docs/backup-policy.md` |
| Risk register | `docs/risks.md` |
| Change records | `docs/changes/` |
| Incident root-cause analyses | `docs/incidents/` |
| Runbooks | `docs/runbooks/` |
| Monitoring stack as code | `monitoring/` |
| Backup and verification scripts | `scripts/linux/` |
| Windows health check | `scripts/windows/` |

## Environment

| Host | OS | RAM | IP | Role |
|---|---|---|---|---|
| DC01 | Windows Server 2022 | 4 GB | 192.168.56.10 | AD DS, DNS, DHCP, SMB share |
| MON01 | Ubuntu 24.04 | 3 GB | 192.168.56.20 | Prometheus, Grafana, Alertmanager, Blackbox |
| BKP01 | Ubuntu 24.04 | 1.5 GB | 192.168.56.30 | restic repository, backup and restore verification |
| CLIENT01 | Windows 10/11 | 2 GB | DHCP | Domain member, started on demand |

Domain: `corp.infralab.test` (NetBIOS `INFRALAB`). Host-only network `VMnet2`,
`192.168.56.0/24`, with VMware's own DHCP disabled so DC01 is the only DHCP
server on the segment.

## Build status

| Phase | Deliverable | Status |
|---|---|---|
| 0 | Repository skeleton, network, ISOs | in progress |
| 1 | DC01 — AD DS, DNS, DHCP, SMB share | not started |
| 2 | CLIENT01 — domain join verification | not started |
| 3 | MON01 — monitoring stack | not started |
| 4 | BKP01 — backups | not started |
| 5 | Restore verification | not started |
| 6 | Windows health checks | not started |
| 7 | Incident simulations | not started |
| 8 | VMware Hands-on Labs | not started |
| 9 | Final documentation pass | not started |

## Credentials

Credentials and repository passwords are stored locally and are not committed
to source control. `.env.example` and `scripts/linux/config.example` show the
required shape with placeholder values.
