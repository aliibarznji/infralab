# Mini Datacenter Infrastructure Lab — Design Spec

**Date:** 2026-07-28
**Status:** Approved
**Repository:** `mini-datacenter-infrastructure-lab`
**Purpose:** Portfolio project demonstrating junior infrastructure engineering competency — virtualization, Windows Server / Active Directory, Linux, monitoring, backup and verified restore, documentation, and change management.

---

## Disclaimer (goes in README verbatim)

> This is an independent personal learning project created to demonstrate infrastructure engineering skills. It is not affiliated with, endorsed by, or produced by any company or organization. No real company systems, data, branding, or logos are used.

---

## 1. Goals

Produce a **portable artifact** — a public Git repository plus screenshots and sample reports — that provides concrete evidence against each responsibility of a junior infrastructure engineering role. The running lab stays on the laptop; the repository is what gets shown.

| Role responsibility | Evidence in this project |
|---|---|
| Administration and monitoring of IT infrastructure and virtualization | VMware Workstation lab, 3+1 VMs, Prometheus/Grafana stack |
| Backup operations | restic backup with retention policy and verified restore tests |
| System health checks and preventive maintenance | Scheduled PowerShell health-check producing an HTML report |
| Monitor performance and report issues | Grafana dashboards, Alertmanager rules, incident records |
| Maintain technical documentation | Architecture, inventory, policies, runbooks |
| Support change management | Change records (CHANGE-NNN) for every structural change |
| Datacenter operations | Asset inventory, IP plan, risk register |
| Collaborate with network / security / application teams | Network segmentation, secrets handling, service monitoring |
| Windows Server, Linux, VMware | DC01 (Server 2022), MON01/BKP01 (Ubuntu), Workstation + vSphere HOL notes |
| Troubleshooting | Incident log with five documented root-cause analyses |

### Non-goals

- Production-grade high availability. This is a single-host lab and says so.
- Real ESXi or vCenter deployment — will not fit in 16 GB. Covered instead by documented VMware Hands-on Labs exercises.
- A second domain controller. Deferred; RAM-constrained.

---

## 2. Constraints

| Constraint | Value |
|---|---|
| Host | Windows 11 Home, 16 GB RAM |
| Hypervisor | VMware Workstation Pro (free for personal use) |
| Concurrent VM budget | ~10 GB, leaving ~5-6 GB for the host |
| Timeline | None. Built in phases, each phase independently demonstrable. |

**RAM rule:** DC01 (4 GB) + MON01 (3 GB) + BKP01 (1.5 GB) = 8.5 GB is the steady-state lab. CLIENT01 (2 GB) is on-demand only, and **BKP01 is shut down while CLIENT01 runs** (4 + 3 + 2 = 9 GB). This constraint is documented in `docs/risks.md` as a lab limitation, not hidden.

---

## 3. Architecture

### Topology

```
                        Host laptop — Windows 11, 16 GB
                        VMware Workstation Pro
                                   │
                 Host-only network: VMnet2
                 192.168.56.0/24 — VMware DHCP DISABLED
                                   │
      ┌──────────────┬─────────────┴─────────────┬──────────────┐
      │              │                           │              │
   DC01 .10      MON01 .20                   BKP01 .30    CLIENT01 (DHCP)
   Win Srv 2022  Ubuntu 24.04                Ubuntu 24.04  Win 10/11
   4 GB          3 GB                        1.5 GB        2 GB, on-demand
      │              │                           │              │
   AD DS         Prometheus                  restic repo    Domain member
   DNS           Grafana                     backup.sh      Proves DHCP,
   DHCP          Alertmanager                verify-restore  GPO, SMB, DNS
   SMB share     Blackbox exporter           check-smb.sh
   windows_exp   node_exporter               node_exporter
```

### Network design

Single custom **host-only** network `VMnet2`, subnet `192.168.56.0/24`, **VMware's own DHCP service disabled on it**. This is mandatory: leaving it enabled puts two DHCP servers on one segment and produces intermittent, hard-to-diagnose address conflicts with DC01's DHCP role.

- Servers use **static** addresses (.10, .20, .30).
- DC01 is the **only** DHCP server. Scope: `192.168.56.100 – 192.168.56.150`.
- DC01 is the only DNS server for the segment. Forwarders configured for external resolution.

**Internet access:** host-only networks have no route out. Each VM gets a second adapter on VMware NAT, used for OS updates and package installation, and **disconnected afterward** so lab traffic stays on VMnet2. DC01 also uses NAT temporarily for Windows Update.

### Domain

| Setting | Value |
|---|---|
| DNS domain | `corp.infralab.test` |
| NetBIOS name | `INFRALAB` |
| Forest/domain functional level | Windows Server 2016 or higher |

`.test` is reserved by RFC 6761 for testing and will never collide with a real public domain. `.local` is deliberately avoided — it is claimed by mDNS (Avahi/Bonjour) and causes confusing resolution behavior on the Ubuntu hosts.

### Accounts

| Account | Purpose | Privilege |
|---|---|---|
| `INFRALAB\Administrator` | Domain administration | Domain Admin — interactive use only |
| `INFRALAB\svc-backup` | BKP01 reads the SMB share | Read-only on the share, no admin rights, no interactive logon |
| `INFRALAB\ali` | Normal domain user, used from CLIENT01 | Domain Users |

The backup service account is deliberately **not** a domain admin. Least privilege is called out explicitly because handling credentials correctly is part of what the project demonstrates.

---

## 4. Components

### 4.1 DC01 — Windows Server 2022

Roles: AD DS, DNS, DHCP, File Services.

- Share `\\DC01\DepartmentData` — the backup source. Populated with representative test files (documents, nested folders) so backup and restore operate on a non-trivial tree.
- Second virtual disk `D:` (5 GB) — the safe target for the disk-capacity incident. **The system disk is never intentionally filled.**
- `windows_exporter` installed as a service, scraped by MON01.
- Health-check script and its scheduled task.

### 4.2 MON01 — Ubuntu 24.04, monitoring

Entire stack runs from a single `docker-compose.yml`. No hand-installed binaries — one file to read, one command to bring the stack up, trivially reproducible.

| Service | Role |
|---|---|
| Prometheus | Scrape and store metrics, evaluate alert rules |
| Grafana | Dashboards, provisioned from files in the repo |
| Alertmanager | Alert routing and grouping |
| Blackbox exporter | ICMP, TCP, DNS, HTTP probes |

`node_exporter` runs natively from the distribution package on both MON01 and BKP01, not in a container — the textfile collector on BKP01 needs a stable host path, and using the same install method on both hosts keeps the scrape configuration uniform.

Grafana dashboards and datasources are **provisioned from the repo**, not clicked together in the UI, so the repository fully describes the monitoring configuration.

### 4.3 BKP01 — Ubuntu 24.04, backup

- Mounts `\\DC01\DepartmentData` **read-only** at `/mnt/dc01-share` using `svc-backup`. Credentials live in `/etc/infralab/smb.cred`, mode `0600`, never committed.
- Local restic repository at `/srv/restic/dc01-share`.
- `node_exporter` with the **textfile collector** enabled — this is how backup and restore results reach Prometheus.
- systemd timers drive `backup.sh` and `verify-restore.sh`.

Backup is a **pull** model: BKP01 reaches into DC01, DC01 has no credentials for and no write access to the backup repository. A compromise or ransomware event on DC01 cannot reach in and destroy the snapshots.

### 4.4 CLIENT01 — Windows 10/11, on-demand

Exists to prove the domain actually works. Without a DHCP client, the DHCP role is configured but never exercised — nothing requests a lease. Started only to demonstrate, then shut down:

- DHCP lease acquisition from DC01's scope
- Domain join
- Domain user logon
- SMB share access
- DNS resolution against DC01
- A Group Policy Object applying

---

## 5. Monitoring design

### Scrape targets

| Target | Exporter | Key metrics |
|---|---|---|
| DC01 | `windows_exporter` | CPU, memory, disk, network, uptime, service state |
| MON01 | `node_exporter` | CPU, memory, filesystem, load, network, uptime |
| BKP01 | `node_exporter` + textfile | Host metrics plus backup/restore custom metrics |

**Windows service monitoring.** Service *names* differ from display names — verify each with `Get-Service` before writing the scrape config rather than guessing. Services watched: `NTDS` (AD DS), `DNS`, `DHCPServer`, `Netlogon`.

### Blackbox probes

| Probe | Target | Answers |
|---|---|---|
| ICMP | DC01, MON01, BKP01 | Is the host reachable? |
| TCP 53 | DC01 | Is the DNS port open? |
| TCP 445 | DC01 | Is the SMB port open? |
| DNS query | DC01, resolving `corp.infralab.test` | Does DNS actually *answer*, not just listen? |
| HTTP | Grafana, Prometheus | Are the web interfaces serving? |

**Blackbox exporter has no SMB module.** A TCP 445 probe proves only that a port is listening — not that the share mounts, that credentials are valid, or that files can be read. Port-open is not service-works. That gap is closed by a custom check.

### Custom metrics via textfile collector

`check-smb.sh` (on BKP01) reads a known test file from the mounted share and emits:

```
infralab_smb_share_available 1
infralab_smb_check_timestamp_seconds 1785234000
```

`backup.sh` and `verify-restore.sh` emit separate metrics. Backup success and restore success are tracked independently, because **a backup can succeed while its restore fails** — and a backup that cannot be restored is not a backup:

```
infralab_backup_last_run_success                     0|1
infralab_backup_last_success_timestamp_seconds       <epoch>
infralab_restore_test_success                        0|1
infralab_restore_test_last_success_timestamp_seconds <epoch>
```

### Alert rules

| Alert | Condition | Severity |
|---|---|---|
| NodeDown | `up == 0` for 2m | critical |
| DiskSpaceLow | filesystem used > 85% for 5m | warning |
| DiskSpaceCritical | filesystem used > 95% for 2m | critical |
| WindowsServiceDown | NTDS / DNS / DHCPServer / Netlogon not running | critical |
| DNSProbeFailed | blackbox DNS probe fails for 3m | critical |
| SMBShareUnavailable | `infralab_smb_share_available == 0` for 5m | warning |
| BackupStale | now − `infralab_backup_last_success_timestamp_seconds` > 26h | critical |
| BackupFailed | `infralab_backup_last_run_success == 0` | critical |
| RestoreTestFailed | `infralab_restore_test_success == 0` | critical |
| RestoreTestStale | now − restore-test timestamp > 8d | warning |

26 hours, not 24: a daily job needs slack for runtime variance and clock drift, or it pages every time the job runs a few minutes late.

---

## 6. Backup design

### Flow

```
\\DC01\DepartmentData
        │  read-only SMB mount (svc-backup)
        ▼
BKP01: /mnt/dc01-share
        │  restic backup
        ▼
BKP01: /srv/restic/dc01-share   (local restic repository)
```

Both scripts run **on BKP01**, driven by systemd timers.

### `backup.sh`

1. Verify `/mnt/dc01-share` is actually mounted and readable. Abort if not — backing up an empty unmounted directory silently produces a valid, useless snapshot.
2. `restic backup /mnt/dc01-share`
3. Apply retention: `restic forget --keep-daily 7 --keep-weekly 4 --keep-monthly 6 --prune`
4. Repository integrity check (see cadence below)
5. Write backup metrics to the textfile collector
6. Exit non-zero on any failure

### `verify-restore.sh`

A backup is only real if it restores. Runs weekly:

1. Restore the latest snapshot to a temporary directory
2. Checksum every file in the live source
3. Checksum every file in the restored tree
4. Sort both lists, compare
5. Emit a clear result and the restore metrics
6. Remove the temporary restore directory
7. Exit non-zero on any mismatch

Output:

```
Restore verification successful
Files checked: 25
Mismatch count: 0
```

The comparison covers the **complete restored tree**, not a single sample file. Verifying one file proves one file.

### Repository check cadence

| Frequency | Command | Cost |
|---|---|---|
| Daily, after backup | `restic check --read-data-subset=N/7` | Structure check plus one rotating seventh of the pack data. Full data coverage completes each week. |

Full `--read-data` on every run re-reads the entire repository daily. That does not scale and is not what production does. The rotating subset gives complete weekly coverage at a seventh of the daily cost.

### Documented lab simplifications

Stated plainly in `docs/backup-policy.md`, because knowing where a lab diverges from production is itself the skill being demonstrated:

- Prune runs immediately after every backup. In production, backup and prune are scheduled separately — prune takes exclusive locks and can run long.
- The backup repository lives on the same physical laptop as its source. This violates 3-2-1 and is recorded in the risk register.
- Retention is short (7/4/6) to keep the lab small. A regulated production environment would have retention requirements measured in years.
- No off-site or immutable copy.

---

## 7. Health checks

`scripts/windows/Invoke-HealthCheck.ps1` on DC01, run daily by a scheduled task installed via `Install-HealthCheckTask.ps1`. Produces a timestamped HTML report.

Checks:

- CPU, memory, disk free space per volume
- Windows service state: NTDS, DNS, DHCPServer, Netlogon
- `dcdiag /test:DNS`
- SYSVOL and NETLOGON share presence
- Domain controller discovery (`nltest /dsgetdc:`)
- System and Application event log errors from the last 24 hours
- Time synchronization source and offset (`w32tm /query /status`)

**No AD replication check.** Replication copies directory data *between* domain controllers. With a single DC there is nothing to replicate, and a replication check would either fail confusingly or pass meaninglessly. The script documents this:

> Replication checks are skipped: this domain has a single domain controller. With a second DC, add `repadmin /replsummary` and `dcdiag /test:Replications`.

A representative report is committed to `sample-reports/health-check-sample.html` so the repository shows the output without needing the lab running.

---

## 8. Incident log

The differentiating section. Each incident is deliberately induced, detected by monitoring, then written up: symptom, detection, timeline, investigation, root cause, fix, prevention.

**Every incident is preceded by a VM snapshot.** Snapshots are the rollback mechanism for the exercise — and `docs/backup-policy.md` notes that a snapshot is not a backup, which is exactly the distinction that matters in a real environment.

| ID | Incident | Safe simulation method |
|---|---|---|
| INC-001 | DC01 disk capacity exhausted | Fill the **separate 5 GB `D:` volume**, never the system disk. Alert fires, investigate, reclaim, discuss capacity planning. |
| INC-002 | DNS service stopped — domain service discovery and new authentication fail | Stop the DNS service. Show `nslookup` failing, DC discovery failing, new domain operations failing, DNS probe alerting. |
| INC-003 | Backup silently stops | Disable the systemd timer, or break the SMB mount. Wait for BackupStale. |
| INC-004 | Kerberos failure from clock skew | Skew **CLIENT01's** clock. Show authentication failure, then resynchronize. |
| INC-005 | Restore verification detects changed backup data | Restore, modify or delete one restored file *before* comparison, show the checksum mismatch caught. |

Three of these need care, and the care is part of the record:

**INC-002 title accuracy.** "DNS stopped, all authentication instantly fails" is wrong and an interviewer may well catch it. Existing sessions often keep working — DNS results are cached, Kerberos tickets remain valid until expiry, and Windows cached credentials permit logon. The accurate framing is *domain service discovery and new authentication fail*, and the writeup explains why the failure is partial. Getting this nuance right is worth more than an incident that overstates its blast radius.

**INC-004 targets the client, not the DC.** DC01 holds the PDC Emulator role and is the authoritative time source for the domain — skewing it cascades to every member and is unpleasant to unwind. Skewing CLIENT01 produces the identical Kerberos failure and reverts cleanly.

**INC-005 does not corrupt the real repository.** Deliberately corrupting restic pack files can damage many snapshots at once and is not reliably recoverable. Modifying restored output tests the exact same detection path — checksum comparison catches a difference — with zero risk. A genuine repository-corruption exercise, if ever done, runs against a **disposable copy** of the repository and is documented as such.

**INC-003 demo threshold.** The production-style rule is 26 hours; waiting 26 hours for a demo is impractical. A temporary parallel rule with a 5-minute threshold is used for the demonstration, and both are shown, with the reason for the difference documented.

---

## 9. Documentation set

| Document | Content |
|---|---|
| `README.md` | Disclaimer, what this is, architecture diagram, phase status, screenshot index |
| `docs/architecture.md` | Topology diagram (Mermaid), network design, IP plan, domain design, rationale |
| `docs/inventory.md` | Asset table: host, OS, IP, purpose, owner, backup status, monitoring status |
| `docs/backup-policy.md` | Scope, schedule, retention, verification, snapshot-vs-backup, lab simplifications |
| `docs/monitoring-policy.md` | What is monitored, thresholds and why, alert routing, escalation |
| `docs/risks.md` | Risk register — see below |
| `docs/runbooks/` | restore-file, restore-full-share, disk-full, dc-wont-boot, dns-failure, add-monitored-host |
| `docs/changes/` | CHANGE-NNN records for each structural change |
| `docs/incidents/` | INC-NNN root-cause analyses |
| `docs/vmware-hol/` | vSphere Hands-on Labs notes: vSphere basics, VMware networking |

The IP plan lives inside `architecture.md` rather than a separate file — it is three rows and belongs next to the diagram it describes. The snapshot-versus-backup discussion lives in `backup-policy.md`, where the decision it informs actually gets made.

### Risk register

Included because pretending a laptop lab equals a production datacenter is the fastest way to lose credibility in an interview.

| Risk | Impact | Mitigation |
|---|---|---|
| Single domain controller | Domain services unavailable if DC01 fails | VM-level backup, documented recovery; production needs 2+ DCs |
| Backup repository on the same physical host as its source | One laptop failure destroys source and backup together | Documented; production requires off-device and off-site copies (3-2-1) |
| No recovery path for the restic encryption key | Backups become permanently unusable | Key material stored securely outside the repository; documented as a recovery prerequisite |
| Single monitoring server | Monitoring blind if MON01 fails | Manual check procedure documented; production needs redundant monitoring |
| No off-site or immutable backup copy | Ransomware or site loss destroys all copies | Documented as a known gap with the production remedy stated |
| 16 GB RAM ceiling | Cannot run all VMs simultaneously | Documented VM start/stop procedure; BKP01 stops while CLIENT01 runs |

### Change management

Every structural change gets a `CHANGE-NNN` record: what changed, why, risk assessment, rollback plan, verification steps, outcome. Initial set: create domain, deploy monitoring, enable backups.

---

## 10. Secrets handling

Non-negotiable for a public portfolio repository. Leaked credentials would undermine the entire project.

Credentials required: domain administrator, `svc-backup`, SMB mount credentials, restic repository password, Grafana admin password.

- Committed: `.env.example` and `scripts/linux/config.example`, with placeholder values and comments.
- Never committed: real credentials, restic password, mount credential files, Grafana/Prometheus data volumes.
- `/etc/infralab/smb.cred` is `chmod 0600`, root-owned, outside the repository tree.

`.gitignore`:

```gitignore
.env
*.password
*.secret
credentials/
restic-password.txt
monitoring/grafana-data/
monitoring/prometheus-data/
*.cred
```

README states: *Credentials and repository passwords are stored locally and are not committed to source control.*

---

## 11. Repository layout

Files are created **when their phase produces them**, not scaffolded empty up front. A tree of empty placeholder files reads as padding; a repository where every file has real content reads as work.

```
mini-datacenter-infrastructure-lab/
├── README.md
├── LICENSE
├── .gitignore
├── .env.example
│
├── docs/
│   ├── architecture.md          # topology, network design, IP plan, domain design
│   ├── inventory.md
│   ├── backup-policy.md         # includes snapshot vs backup
│   ├── monitoring-policy.md
│   ├── risks.md
│   ├── runbooks/
│   ├── changes/
│   ├── incidents/
│   └── vmware-hol/
│
├── scripts/
│   ├── windows/
│   │   ├── Invoke-HealthCheck.ps1
│   │   └── Install-HealthCheckTask.ps1
│   └── linux/
│       ├── backup.sh
│       ├── verify-restore.sh
│       ├── check-smb.sh
│       └── config.example
│
├── monitoring/
│   ├── docker-compose.yml
│   ├── prometheus/
│   │   ├── prometheus.yml
│   │   └── alerts.yml
│   ├── alertmanager/alertmanager.yml
│   ├── blackbox/blackbox.yml
│   └── grafana/
│       ├── provisioning/
│       └── dashboards/
│
├── sample-reports/
│   └── health-check-sample.html
│
└── screenshots/
    ├── architecture/
    ├── active-directory/
    ├── monitoring/
    ├── backups/
    ├── restore-tests/
    └── incidents/
```

---

## 12. Verification

Non-trivial logic leaves a runnable check behind:

| Component | Check |
|---|---|
| `verify-restore.sh` | Is itself the check for the backup path. Exits non-zero on mismatch. |
| `backup.sh` | Mount guard aborts on unmounted source; non-zero exit on any failure. |
| `check-smb.sh` | Emits `0` on read failure; the alert rule is the assertion. |
| `Invoke-HealthCheck.ps1` | `-SelfTest` switch runs the checks against known values and asserts the HTML renders. |
| `monitoring/` | `promtool check config` and `promtool check rules` before commit. |
| Alert rules | `promtool test rules` with a small unit-test file asserting BackupStale and WindowsServiceDown fire on synthetic series. |

No test framework. No fixtures. Each check is the smallest thing that fails when the logic breaks.

---

## 13. Build phases

Each phase ends with something demonstrable, its documentation, and a commit. The project is presentable at the end of any phase.

| Phase | Deliverable |
|---|---|
| 0 | Repo initialized, README with disclaimer, `.gitignore`, Workstation installed, VMnet2 created with VMware DHCP disabled, ISOs downloaded |
| 1 | DC01 built: AD DS, DNS, DHCP, SMB share, `D:` volume. `CHANGE-001`. `architecture.md`, `inventory.md`. |
| 2 | CLIENT01 built on demand: DHCP lease, domain join, user logon, share access, GPO applied. Screenshots. |
| 3 | MON01: docker-compose stack up, DC01 and MON01 scraped, blackbox probes, Grafana dashboards provisioned. `CHANGE-002`, `monitoring-policy.md`. |
| 4 | BKP01: SMB mount, restic repo, `backup.sh`, `check-smb.sh`, systemd timers, metrics flowing. `CHANGE-003`, `backup-policy.md`. |
| 5 | `verify-restore.sh` weekly, restore metrics, restore alert rules, restore-file and restore-full-share runbooks. |
| 6 | `Invoke-HealthCheck.ps1` + scheduled task, sample HTML report committed. |
| 7 | INC-001 through INC-005 induced, detected, documented. Remaining runbooks. `risks.md`. |
| 8 | VMware Hands-on Labs completed and written up. |
| 9 | Final pass: README polish, architecture diagram, screenshot index, repository review for leaked secrets. |

---

## 14. Open items

- Windows Server 2022 evaluation ISO (180-day) versus Server 2025 — decide at Phase 0. Evaluation editions are appropriate for a lab and their use should be stated.
- Grafana dashboard sourcing: community dashboard IDs for node_exporter and windows_exporter as a starting point, then customized. Provenance is credited rather than passed off as original.
- Alertmanager notification target — local webhook receiver is sufficient; email requires SMTP credentials for no additional demonstrated skill.
