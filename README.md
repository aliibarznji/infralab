# Mini Datacenter Infrastructure Lab

A self-hosted lab simulating a small company IT environment: Active Directory domain services, centralised file storage, monitoring, automated backup with verified disaster recovery, and documented incident response.

Built on VMware Workstation Pro on a single laptop (16 GB RAM, i7-11800H), fully isolated on a host-only network.

---

## Architecture

```
                    Host-only network: VMnet2
                       192.168.56.0/24
                  (VMware DHCP disabled — DC01 serves DHCP)

  ┌──────────────┬──────────────┬──────────────┬──────────────┐
  │    DC01      │    MON01     │    BKP01     │   CLIENT01   │
  │ 192.168.56.10│ 192.168.56.20│ 192.168.56.30│192.168.56.101│
  │              │              │              │    (DHCP)    │
  │ Win Server   │ Ubuntu 26.04 │ Ubuntu 26.04 │ Windows 11   │
  │ 2022 Std     │              │              │ Pro          │
  │ 4 GB RAM     │ 3 GB RAM     │ 1.5 GB RAM   │ 4 GB RAM     │
  ├──────────────┼──────────────┼──────────────┼──────────────┤
  │ AD DS        │ Prometheus   │ Restic       │ Domain-joined│
  │ DNS          │ Grafana      │ CIFS mount   │ SSO to share │
  │ DHCP         │ Node Exporter│ Cron backup  │              │
  │ SMB share    │ Health checks│              │              │
  └──────────────┴──────────────┴──────────────┴──────────────┘
```

| Role | Host | Purpose |
|---|---|---|
| Domain Controller | DC01 | Identity, name resolution, address assignment, file services |
| Monitoring | MON01 | Metrics collection, dashboards, scheduled health checks |
| Backup | BKP01 | Encrypted, deduplicated, automated off-host backup |
| Workstation | CLIENT01 | End-user machine validating the domain from a user's perspective |

---

## DC01 — Domain Controller (Windows Server 2022)

**Forest / domain:** `lab.local`

**Roles installed:** AD DS, DNS, DHCP, File and Storage Services

**Organisational Unit structure**

```
lab.local
└── Company
    ├── Computers   → CLIENT01
    ├── Employees   → user account "Ali"
    └── Groups      → security group "IT-Team" (Global / Security)
```

**File share:** `CompanyShare` → `C:\CompanyShare`

### Access control

The share was initially created with the default `Everyone: Full Control`, which grants access to any authenticated principal and is not acceptable in a production environment. It was replaced with group-based access:

**Share permissions**

| Principal | Access |
|---|---|
| `LAB\IT-Team` | Full Control |

`Everyone` removed.

**NTFS permissions**

| Principal | Access | Applies to |
|---|---|---|
| SYSTEM | Full control | This folder, subfolders and files |
| Administrators | Full control | This folder, subfolders and files |
| CREATOR OWNER | Full control | Subfolders and files only |
| `LAB\IT-Team` | Full control | This folder, subfolders and files |

Inheritance from `C:\` was disabled and inherited entries removed, because the parent volume propagates `Users` (Read & Execute), which would have re-granted read access to every domain user and silently defeated the share-level restriction. Permissions were then pushed down to existing child objects.

Both layers were tightened. Effective access on an SMB share is the intersection of share and NTFS permissions, so leaving NTFS at defaults would have left the folder over-permissive to anyone accessing it locally or via a different share path.

### Verification

Access was tested from CLIENT01 as `lab\ali`:

- Read: directory listing succeeded
- Write: file creation initially returned *Destination Folder Access Denied*

`whoami /groups` showed no domain groups in the token — the session was running on a cached logon issued before `IT-Team` existed. Group membership is written into the access token at logon and is not refreshed live. After signing out and back in, the token contained `LAB\IT-Team` and both read and write succeeded.

Read had appeared to work during the failure because the SMB session was already established; only the new write operation triggered a fresh authorisation check.

---

## MON01 — Monitoring (Ubuntu 26.04)

| Component | Version | Port |
|---|---|---|
| Prometheus | 3.13.1 | 9090 |
| Grafana | 13.1.1 | 3000 |
| Node Exporter | — | 9100 |

All run as systemd services. Dashboard: *Node Exporter Full* (Grafana ID 1860), showing live CPU, memory, disk, and network metrics.

The NAT adapter was removed after setup so the host sits only on VMnet2, keeping the lab isolated from the internet.

### Scheduled health checks

`/usr/local/bin/health-check.sh` runs hourly via cron and logs to `/var/log/health-check.log`. It verifies:

- ICMP reachability of DC01 and BKP01
- DNS resolution of `dc01.lab.local` against DC01
- `active` state of prometheus, grafana-server, prometheus-node-exporter
- Root filesystem usage, warning above 80%

Sample output:

```
===== Wed Jul 29 09:32:52 AM UTC 2026 =====
OK   ping 192.168.56.10
OK   ping 192.168.56.30
OK   dns dc01.lab.local
OK   service prometheus
OK   service grafana-server
OK   service prometheus-node-exporter
OK   disk / 68%
```

The first run reported `FAIL service node_exporter`. The service was in fact healthy — the packaged unit is named `prometheus-node-exporter`. A monitoring check that reports a false failure is a real defect, since alert fatigue leads to genuine alerts being ignored, so the script was corrected rather than the result being dismissed.

---

## BKP01 — Backup (Ubuntu 26.04)

**Tool:** Restic 0.18.1 — encrypted, deduplicated, snapshot-based

**Repository:** `/var/backups/restic-repo`

**Source:** DC01's `CompanyShare`, mounted over CIFS at `/mnt/dc01-share` via `/etc/fstab`

**Schedule:** `0 2 * * *` — daily at 02:00 via cron

### Credential handling

| File | Purpose | Mode |
|---|---|---|
| `/etc/dc01-creds` | CIFS mount credentials | 600 |
| `/etc/restic-pass` | Restic repository password | 600 |

Both are root-owned and mode 600 so the scheduled job can authenticate unattended without secrets appearing in the crontab, the script body, or process arguments visible to other users via `ps`.

### Disaster recovery test

A backup that has never been restored is not a backup. The full loop was tested end to end:

1. Deleted `test1.txt` from `CompanyShare` on DC01
2. Restored snapshot `7e7efe70` to `/tmp/restore-test` on BKP01
3. Verified restored file contents matched the original
4. Copied the file back to the live share
5. Confirmed it reappeared on DC01

Backups were re-verified after the permission lockdown described above, confirming the tightened ACLs did not break unattended access — the backup account is a member of `IT-Team`.

**Operational note:** snapshots created by the cron job are owned by root. Restic commands against those snapshots must be run with `sudo` or they fail with permission errors on the repository files.

---

## CLIENT01 — Workstation (Windows 11 Pro)

Windows 11 **Pro** was chosen over Home because Home cannot join an Active Directory domain.

**Installation note:** Windows 11 OOBE requires internet connectivity before allowing local account creation, which is impossible on an isolated network. The documented `BypassNRO` registry method did not work reliably on this build. Working method: `Shift + F10` at the OOBE screen → `start ms-cxh:localonly` → close the resulting window, which drops through to local account creation.

**Verified after domain join:**

| Check | Result |
|---|---|
| DHCP lease from DC01 | `192.168.56.101` |
| DNS suffix | `lab.local` |
| Domain join | `lab.local` |
| `whoami` | `lab\ali` |
| `%USERDNSDOMAIN%` | `LAB.LOCAL` |
| Share access | `\\DC01\CompanyShare` via SSO, no credential prompt |
| Computer object | Present in `Company > Computers` OU |

---

## Incident Response

### INC-001 — Name resolution failure

**Symptom:** Users report the file share is unreachable by its full name.

**Investigation**

| Test | Result | Conclusion |
|---|---|---|
| `ping 192.168.56.10` | 4/4 replies, 0% loss | Network and host are up — not a connectivity fault |
| `nslookup dc01.lab.local` | Request timed out | Name resolution is the failing layer |
| `dir \\192.168.56.10\CompanyShare` | Succeeded | SMB service healthy |
| `dir \\dc01\CompanyShare` | Succeeded | Short name resolved without DNS |
| `dir \\dc01.lab.local\CompanyShare` | Failed | FQDN requires DNS |

**Root cause:** The DNS Server service on DC01 had stopped.

**Notable finding:** The short name continued to work throughout the outage, resolved by NetBIOS/LLMNR broadcast fallback on the local subnet. This is exactly the kind of partial symptom that misleads triage — some users would report no problem at all, while anything depending on the FQDN, and therefore anything Kerberos-dependent, would fail. Testing by IP, short name, and FQDN separately is what isolated the fault to the resolution layer rather than the file service.

**Resolution**

```powershell
Start-Service DNS
```

```cmd
ipconfig /flushdns
```

Client resolver cache was flushed because it had negatively cached the failed lookups.

**Verification:** `nslookup dc01.lab.local` returned `192.168.56.10`; FQDN share access restored.

**Preventive action:** Service recovery configured on the DNS Server service — restart on first, second, and subsequent failures, with a one-minute delay. The hourly health check on MON01 independently tests DNS resolution, so a repeat failure surfaces in the log rather than waiting on a user report.

---

## Repository contents

The lab runs on a laptop. This repository is the part that travels — the
configuration, the automation, and the operational documentation.

### Operational documentation

| Document | Contents |
|---|---|
| [`docs/inventory.md`](docs/inventory.md) | Hosts, services, accounts, scheduled work, versions |
| [`docs/monitoring-policy.md`](docs/monitoring-policy.md) | What is monitored, every threshold and why it is that number |
| [`docs/backup-policy.md`](docs/backup-policy.md) | Scope, retention, verification, why a snapshot is not a backup |
| [`docs/risks.md`](docs/risks.md) | Risk register, accepted risks, and risks closed |

### Runbooks

| Runbook | For |
|---|---|
| [`deploy-monitoring.md`](docs/runbooks/deploy-monitoring.md) | Deploying alerting and backup metrics across all four hosts |
| [`restore-file.md`](docs/runbooks/restore-file.md) | Restoring a single file a user has lost |
| [`dns-failure.md`](docs/runbooks/dns-failure.md) | DNS resolution failure, including the fallback paths that mask it |
| [`disk-full.md`](docs/runbooks/disk-full.md) | Disk space exhaustion on either platform |
| [`dc-wont-boot.md`](docs/runbooks/dc-wont-boot.md) | Domain controller recovery, and what a rebuild would cost |
| [`add-monitored-host.md`](docs/runbooks/add-monitored-host.md) | Bringing a new host under monitoring |

### Configuration and automation

| Path | Contents |
|---|---|
| `monitoring/prometheus/` | Scrape config, 15 alert rules, promtool unit tests |
| `monitoring/blackbox/` | DNS, TCP and ICMP probe modules |
| `monitoring/alertmanager/` | Routing, grouping and inhibition |
| `monitoring/grafana/` | Provisioned datasource and backup dashboard |
| `scripts/linux/` | Backup, restore verification, alert receiver, systemd units |
| `scripts/windows/` | Domain controller health check and its scheduled task |

Alert rules are covered by `promtool` unit tests that run against synthetic
series, so a rule can be proven to fire correctly without waiting for the
condition to occur. The Windows health check carries a `-SelfTest` switch that
validates its rendering logic without touching a live system.

---

## Skills Demonstrated

| Area | Detail |
|---|---|
| Active Directory | Forest deployment, OU design, users, security groups, domain join |
| Windows Server | DNS, DHCP, SMB file services, service recovery configuration |
| Access control | Share and NTFS permissions, inheritance, group-based access, token behaviour |
| Linux administration | systemd services, cron, CIFS mounts via fstab, secure credential files |
| Monitoring | Prometheus, Grafana, node and Windows exporters, blackbox probes, scripted health checks |
| Alerting | Alert rules with unit tests, Alertmanager routing and inhibition, custom metrics from backup jobs |
| Backup & recovery | Encrypted snapshot backup, unattended scheduling, automated and verified restore testing |
| Troubleshooting | Layered isolation of a fault, root cause analysis, preventive remediation |
| Documentation | Runbooks, policies, risk register, incident records |

---

## Known Limitations

Deliberately noted rather than hidden — this is a learning lab, not a production build.

- **Single domain controller.** No redundancy; DC01 is a single point of failure for identity, DNS, and DHCP. Production would run at least two.
- **Backups are on-site.** BKP01 holds the only copy and sits on the same physical host as DC01. This satisfies neither the "2 media" nor "1 off-site" parts of the 3-2-1 rule.
- **Lab-grade passwords.** Credentials follow a predictable pattern and would need rotation, length, and a proper secrets store before anything resembling production use.
- **The domain uses `.local`.** That suffix is reserved for multicast DNS, and a name under `.test` would have been correct. Not observed to cause a problem here, and accepted rather than rebuilt — the reasoning is in the risk register.
- **The AD database is not backed up.** Only `CompanyShare` is protected. DC01 relies on VM snapshots, which are not backups.
- **No certificate services or centralised logging.** PKI and syslog aggregation are the natural next additions.

The full register, including likelihood, mitigations actually in place, and the
risks that have been closed, is in [`docs/risks.md`](docs/risks.md).
- **Health check logs locally only.** Results are written to a file on MON01; they are not yet exported to Prometheus or alerted on.