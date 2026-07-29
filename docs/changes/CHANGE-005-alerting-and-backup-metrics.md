# CHANGE-005 — Alerting, blackbox probes and backup metrics

| Field | Value |
|---|---|
| Date | _to be recorded_ |
| Implemented by | Ali |
| Category | Standard |
| Risk | Medium — a bad rules file stops Prometheus from starting |
| Affected systems | MON01, BKP01, DC01 |
| Downtime | Brief Prometheus reload |

> **Status: in progress.** Update this record as the deployment completes. The
> procedure is [`docs/runbooks/deploy-monitoring.md`](../runbooks/deploy-monitoring.md).

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
only once by hand.

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

| Check | Expected |
|---|---|
| `promtool check config /etc/prometheus/prometheus.yml` | SUCCESS |
| `curl localhost:9090/api/v1/rules` | 15 rules in 3 groups |
| `curl 'localhost:9115/probe?target=192.168.56.10&module=dns_soa'` | `probe_success 1` |
| `up{job="windows"}` | 1 |
| Textfile probe metric served by node_exporter on BKP01 | present |
| `backup-dc01.sh` with the share unmounted | exit 1, `mount_ok 0`, previous success timestamp preserved, no new snapshot |
| `verify-restore.sh` | `Mismatch count: 0` |

## Outcome

_To be recorded on completion._
