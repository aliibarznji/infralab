# Asset inventory

Updated whenever a host is added, retired, or changes role.

## Hosts

| Host | OS | IP | Purpose | Backed up | Monitored |
|---|---|---|---|---|---|
| DC01 | Windows Server 2022 Standard (evaluation) | 192.168.56.10 | AD DS, DNS, DHCP, SMB file share | `CompanyShare` pulled to BKP01 | windows_exporter :9182, blackbox probes |
| MON01 | Ubuntu 26.04 | 192.168.56.20 | Prometheus, Grafana, Alertmanager, blackbox exporter, alert-sink | Configuration only, in Git | node_exporter :9100 |
| BKP01 | Ubuntu 26.04 | 192.168.56.30 | restic repository, backup and restore verification | Repository integrity check only | node_exporter :9100 + textfile metrics |
| CLIENT01 | Windows 11 Pro | DHCP, 192.168.56.101 | On-demand domain member used to verify the domain from a user's perspective | No, deliberately | No, deliberately |

CLIENT01 is disposable: rebuilt rather than repaired. Recording that decision is
more useful than pretending everything is protected equally.

MON01 holds no unique state. Every dashboard, datasource, scrape config and
alert rule is provisioned from this repository, so its recovery procedure is
redeploy, not restore.

## Services

| Service | Host | Port | Depends on |
|---|---|---|---|
| Active Directory Domain Services | DC01 | 389, 636, 88 | DNS on DC01 |
| DNS | DC01 | 53 | — |
| DHCP | DC01 | 67 | AD authorisation |
| SMB — `CompanyShare` | DC01 | 445 | AD authentication |
| windows_exporter | DC01 | 9182 | — |
| Prometheus | MON01 | 9090 | All exporters |
| Grafana | MON01 | 3000 | Prometheus |
| Alertmanager | MON01 | 9093 | Prometheus |
| Blackbox exporter | MON01 | 9115 | — |
| alert-sink | MON01 | 9094 (loopback) | Alertmanager |
| node_exporter | MON01, BKP01 | 9100 | — |
| restic repository | BKP01 | local disk | CIFS mount from DC01 |

## Accounts and groups

| Principal | Type | Purpose |
|---|---|---|
| `LAB\Administrator` | Domain Admin | Domain administration, interactive use only |
| `LAB\ali` | Domain user | Ordinary user account, used from CLIENT01 |
| `LAB\IT-Team` | Global security group | Sole principal with access to `CompanyShare`, on both share and NTFS ACLs |

## Directory structure

```
lab.local
└── Company
    ├── Computers   → CLIENT01
    ├── Employees   → ali
    └── Groups      → IT-Team
```

## Scheduled work

| Job | Host | Schedule | Emits |
|---|---|---|---|
| `backup-dc01.sh` | BKP01 | Daily 02:00 | `infralab_backup_*` |
| `verify-restore.sh` | BKP01 | Weekly, Sunday 03:00 | `infralab_restore_test_*` |
| `health-check.sh` | MON01 | Hourly | `/var/log/health-check.log` |
| `Invoke-HealthCheck.ps1` | DC01 | Daily 06:00 | HTML report in `C:\HealthChecks` |

## Files holding credentials

Never committed. Listed here so they are known, not so they are readable.

| Path | Host | Contents | Mode |
|---|---|---|---|
| `/etc/dc01-creds` | BKP01 | CIFS mount credentials for the backup account | 0600, root |
| `/etc/restic-pass` | BKP01 | restic repository password | 0600, root |

The restic password has no recovery path. Losing it makes every snapshot
permanently unreadable — see `risks.md`.

## Versions

| Component | Version |
|---|---|
| VMware Workstation Pro | 26H1 |
| Windows Server | 2022 Standard, evaluation edition |
| Ubuntu Server | 26.04 |
| Windows client | 11 Pro |
| Prometheus | 3.13.1 |
| Grafana | 13.1.1 |
| restic | 0.18.1 |
| windows_exporter | 0.31.8 |

Windows Server is an evaluation edition and expires 180 days from installation.
Recorded in `risks.md` rather than left to be discovered.
