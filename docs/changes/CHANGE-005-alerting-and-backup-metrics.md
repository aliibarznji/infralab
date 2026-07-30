# CHANGE-005 — Alerting, blackbox probes and backup metrics

| Field | Value |
|---|---|
| Date | _to be recorded_ |
| Implemented by | Ali |
| Category | Standard |
| Risk | Medium — a bad rules file stops Prometheus from starting |
| Affected systems | MON01, BKP01, DC01 |
| Downtime | Brief Prometheus reload |

> **Status: deployed.** Verification results below are real, gathered during the
> deployment described in
> [`docs/runbooks/deploy-monitoring.md`](../runbooks/deploy-monitoring.md).

## Reason

CHANGE-002 delivered collection and dashboards but no alerting. INC-001 proved
the consequence: the DNS service was stopped and nothing reported it, because
every check that existed passed. Dashboards only help when someone is looking at
them.

Three specific gaps closed here:

1. **Nothing alerted on anything.** No Alertmanager, no rules loaded.
2. **No check asked DNS a question.** ICMP answered and short names resolved via
   NetBIOS throughout the INC-001 outage.
3. **Backup failures were invisible.** The job wrote no metrics, so a backup that
   stopped running would have been discovered only when a restore was needed.

## What changed

**DC01** — windows_exporter with the `ad`, `dns` and `service` collectors, the
service filter scoped to `NTDS|DNS|DHCPServer|Netlogon`, and a firewall rule on
9182 permitting only MON01.

**MON01** — Alertmanager and blackbox exporter as systemd services; 15 alert
rules; `alert-sink`, a standard-library webhook receiver on loopback that logs
every notification with its firing time; Grafana datasource and the backup
dashboard provisioned from the repository rather than clicked together.

**BKP01** — node_exporter with the textfile collector; `backup-dc01.sh` rewritten
to publish exit code, last-success timestamp, snapshot count and mount status;
`verify-restore.sh` added to automate the restore test that CHANGE-003 performed
only once by hand. Both scripts moved from cron to systemd timers with
`Persistent=true`, so a run missed while BKP01 is powered off (which happens
whenever CLIENT01 is in use, to stay inside the RAM budget) executes at next
boot instead of being silently skipped.

## Design decisions worth recording

**Metrics publish on failure, not just success.** The scripts write their metrics
from an `EXIT` trap. If a failing job simply stopped writing, its series would go
stale and then absent — and an alert comparing against a series that no longer
exists never fires. The last-success timestamp is held in a separate state file
so a failed run reports the true previous value rather than clearing it.

**Backup and restore are tracked separately.** A backup can complete cleanly and
still be unrestorable. A single "backups healthy" indicator would hide exactly
the failure that costs the most.

**A mount guard was added.** An unmounted CIFS mountpoint is an empty directory,
and backing it up produces a valid, entirely empty snapshot that then satisfies
every freshness check while protecting nothing.

**The DNS check is a SOA query, not a port check.** A TCP probe on 53 proves
something is listening, which was never the failing condition in INC-001.

**The mount guard was tested against a real failure, not a simulated one.**
`/mnt/dc01-share` turned out to be managed by autofs rather than a static
`/etc/fstab` mount, so `umount` alone does not produce a failure — autofs
remounts on the next access. DC01 was powered off instead, which genuinely
prevents the automount from succeeding. See
[`docs/incidents/INC-003-stale-backup.md`](../incidents/INC-003-stale-backup.md)
and the autofs note in `docs/backup-policy.md`.

## Risk assessment

| Risk | Mitigation |
|---|---|
| An invalid rules file prevents Prometheus starting, taking all monitoring down | `promtool check config` before every reload; the runbook gates the reload on it |
| Alert rules that never fire, or fire constantly | 15 rules covered by promtool unit tests against synthetic series, verified failing before the rules existed |
| windows_exporter service filter matching nothing | Service names confirmed with `Get-Service` before configuring, not assumed |
| Metrics endpoint exposes host inventory | Firewall rule on DC01 scoped to MON01; blackbox and alert-sink bound to loopback |

## Rollback

`systemctl disable --now prometheus-alertmanager prometheus-blackbox-exporter
infralab-alert-sink`, restore the previous `prometheus.yml`, reload. The backup
script's previous version can be restored from Git. No data is at risk.

## Verification

| Check | Expected | Result |
|---|---|---|
| `promtool check config /etc/prometheus/prometheus.yml` | SUCCESS | Passed |
| `curl localhost:9090/api/v1/rules` | 15 rules in 3 groups | Passed |
| `up{job="windows"}` | 1 | Confirmed — DC01 windows_exporter scraping successfully |
| Textfile metrics served by node_exporter on BKP01 | present | Confirmed |
| `backup-dc01.sh` against an unreachable share | exit 1, `mount_ok 0`, previous success timestamp preserved, no new snapshot | Confirmed — see INC-003 for the method actually used |
| `backup-dc01.sh` after recovery | exit 0, `mount_ok 1`, snapshot count incremented | Confirmed — snapshot count went to 5 |
| `verify-restore.sh` | `Mismatch count: 0` | Passed |
| Cron → systemd timer migration | `infralab-backup.timer`, `infralab-restore-test.timer` active, `Persistent=true` | Completed |

## Outcome

Completed. All alerting, probing and backup-metric infrastructure described
above is deployed and verified on the running lab. The mount-guard test
surfaced a design detail not anticipated at write time — autofs rather than a
static mount — recorded in `docs/backup-policy.md` and `INC-003`.
