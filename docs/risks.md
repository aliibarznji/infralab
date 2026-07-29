# Risk register

A laptop lab is not a production datacenter. Recording exactly where it differs
is more credible, and more useful, than implying the two are equivalent.

| Risk | Impact | Likelihood | Mitigation in place | Production remedy |
|---|---|---|---|---|
| Single domain controller | All domain services unavailable if DC01 fails. No failover, and authentication, DNS and DHCP all fail together | Medium | VM snapshots, documented recovery | Two or more DCs in separate failure domains |
| Backup repository on the same physical host as its source | One laptop failure destroys the share and every snapshot of it. Breaks 3-2-1 outright | Medium | Repository integrity checked on every run | Off-device and off-site copies, at least one immutable |
| No recovery path for the restic repository password | Every snapshot becomes permanently unreadable. There is no vendor reset | Low | `/etc/restic-pass` mode 600, password also held in a password manager outside this repository | Key escrow with a documented and periodically tested recovery |
| Cron does not catch up missed runs | BKP01 is shut down whenever CLIENT01 runs, and a backup scheduled during that window is skipped entirely rather than deferred | **High** | `BackupStale` alerts after 25h, so a skipped run is visible rather than silent | systemd timers with `Persistent=true`, which run the job at next boot |
| Single monitoring host | If MON01 is down nothing is being watched, and nothing reports that fact | Medium | Manual check procedure; the Windows health check runs independently on DC01 | Redundant collection plus external dead-man monitoring |
| No authentication on Prometheus or Alertmanager | Anyone reaching those ports can read the full estate inventory, force a config reload, or silence alerts. A silenced alert is indistinguishable from no incident | Low on an isolated segment | Bound to the lab interface; the segment has no route to the internet | Authenticating reverse proxy in front of both |
| CIFS credentials stored on disk | `/etc/dc01-creds` allows read access to CompanyShare to anyone who can read the file | Low | Mode 600, root-owned, referenced by fstab rather than embedded in the mount command | Kerberos-authenticated mounts with no stored password |
| 16 GB RAM ceiling | All four VMs cannot run at once, so BKP01 is stopped while CLIENT01 is in use | High | Documented start/stop procedure; monitoring detects the resulting gaps | Adequate capacity, no host contention |
| No system state backup of DC01 | The AD database is protected only by VM snapshots, and a snapshot is not a backup | Medium | Documented below | Windows Server Backup system state, or an AD-aware backup product |
| Windows Server evaluation edition | The installation expires after 180 days | Certain | Documented; the lab is rebuilt or relicensed before expiry | Properly licensed editions |
| Domain uses `.local` | `.local` is reserved for multicast DNS (Avahi, Bonjour). Linux hosts can resolve it via mDNS instead of the domain controller, giving intermittent and misleading resolution behaviour | Low, and not observed so far | Resolution verified working from MON01 and BKP01; `dc01.lab.local` resolves against DC01 | See below |

## The `.local` deviation

The domain was built as `lab.local`. The better choice is a name under `.test`,
which RFC 6761 reserves for exactly this purpose and which nothing else claims.

`.local` is claimed by multicast DNS. On a Linux host running Avahi or
systemd-resolved with mDNS enabled, a `.local` lookup can be answered by mDNS
rather than by the domain controller. When that happens the symptom is not a
clean failure — it is a name that resolves to the wrong thing, or resolves
sometimes, which is considerably harder to diagnose than a name that simply does
not resolve.

This has not been observed in the lab: resolution of `dc01.lab.local` from both
Ubuntu hosts goes to DC01 and returns the correct address.

**Decision: accept and document rather than rebuild.** Renaming an Active
Directory domain is disruptive and, in practice, usually done by rebuilding the
forest. The cost of that outweighs a risk that is real but has not materialised
in an isolated single-segment lab. In a production build the name would be
chosen correctly at the start, because this is precisely the class of decision
that is cheap before deployment and expensive afterwards.

Related note: INC-001 showed short names still resolving through NetBIOS/LLMNR
while DNS was stopped. Both that and the `.local` choice come from the same
place — name resolution on a Windows network has several fallback paths, and
they can mask the failure of the one you meant to rely on.

## A snapshot is not a backup

VM snapshots are used in this lab to roll back incident simulations, and they
are the right tool for that. They are not backups:

- A snapshot lives on the same disk as the VM it protects. One disk failure
  takes both.
- A snapshot is a delta chain against a running disk, not an independent copy.
- Snapshots grow without bound and degrade performance. They are a short-lived
  operational tool, not a retention mechanism.
- A file corrupted inside the guest is faithfully preserved by the snapshot.

The restic repository is the backup. The snapshots are an undo button.

## Accepted risks

The RAM ceiling, the single-host topology and the co-located backup repository
are accepted deliberately. They are inherent to a laptop lab, and removing them
would mean not building it. The mitigations above reduce their consequences
rather than eliminating their causes — which is the honest description of most
risk management.

## Risks closed

| Risk | Closed by |
|---|---|
| `Everyone: Full Control` on CompanyShare granted every authenticated principal full access | Replaced with `LAB\IT-Team` on both share and NTFS ACLs; inheritance from `C:\` disabled because it was re-granting `Users: Read & Execute` |
| A stopped DNS service was not visible to monitoring | Blackbox SOA probe against DC01, plus `windows_service_state` alerting on the DNS service |
| DNS service stayed down after failing | Service recovery configured to restart on first, second and subsequent failure; verified by the daily health check |
| Backup failures were invisible until someone needed a restore | `backup-dc01.sh` publishes exit code, last-success timestamp, snapshot count and mount status to Prometheus; `BackupStale` alerts at 25h |
| Restore was proven once by hand and never again | `verify-restore.sh` runs weekly and checksums the full restored tree |
