# Monitoring policy

## Principle

Monitor what people depend on, not what is easy to measure. A port that accepts
a connection is not a service that works. Every external check that could be
deepened from "is it listening" into "does it answer" has been.

INC-001 is the reason this is stated first rather than as an afterthought.
Stopping the DNS service on DC01 did not look like an outage from outside: ICMP
still answered, and short-name lookups still resolved through NetBIOS/LLMNR
fallback. The service was down and most surface-level checks said it was fine.

## What is monitored

| Target | Method | Endpoint |
|---|---|---|
| DC01 host and Windows services | windows_exporter | 192.168.56.10:9182 |
| MON01 host | node_exporter | 192.168.56.20:9100 |
| BKP01 host, backup and restore outcomes | node_exporter + textfile collector | 192.168.56.30:9100 |
| DC01 reachability | blackbox ICMP | via 9115 |
| DNS and SMB and Kerberos ports on DC01 | blackbox TCP 53, 445, 88 | via 9115 |
| DNS actually answering for `lab.local` | blackbox DNS SOA query | via 9115 |
| Linux service and disk state | `health-check.sh`, hourly cron | `/var/log/health-check.log` |
| DC health, shares, event log, time | `Invoke-HealthCheck.ps1`, daily | HTML report |

### Why there is both a TCP probe and a DNS probe against port 53

The TCP probe proves something is bound to port 53. The DNS probe asks for the
SOA record of `lab.local` and requires `NOERROR`. Only the second one fails when
the service is running but not answering for its zone, which is the failure mode
that matters and the one INC-001 demonstrated is easy to miss.

## Thresholds and the reasoning behind them

| Alert | Threshold | Why this number |
|---|---|---|
| NodeDown | `up == 0` for 2m | Two missed 30s scrapes plus margin. Shorter alerts on every restart. |
| DiskSpaceLow | > 85% for 5m | Room to act before anything breaks. |
| DiskSpaceCritical | > 95% for 2m | Failure imminent; the shorter window is deliberate. |
| WindowsServiceDown | not running for 2m | Tolerates a service restarting during patching. |
| DNSProbeFailed | 3m | DNS is a dependency of nearly everything else here. |
| TCPProbeFailed / ICMPProbeFailed | 3m | Matches the DNS window; these fail together during a host outage. |
| BackupStale | > 25h | Not 24h. A daily job needs slack for runtime variance, or it alerts every time it runs a few minutes late. |
| BackupFailed | exit code non-zero | Immediate. The job itself reported failure. |
| BackupMountMissing | mount flag 0 for 5m | The share was unavailable at backup time. |
| BackupSnapshotCountDropped | fall of more than 1 in 2h | Retention removes at most one snapshot per daily run. A larger drop means something else did it. |
| RestoreTestFailed | test result 0 | Immediate. The most serious signal in this system. |
| RestoreTestStale | > 8d | The test runs weekly; 8 days allows one missed run. |

## Backup and restore are separate signals

The backup job publishes five metrics rather than one health flag:

```
infralab_backup_last_run_exit_code
infralab_backup_last_run_timestamp_seconds
infralab_backup_last_success_timestamp_seconds
infralab_backup_snapshot_count
infralab_backup_mount_ok
```

and the restore verification publishes four more:

```
infralab_restore_test_success
infralab_restore_test_files_checked
infralab_restore_test_mismatches
infralab_restore_test_last_success_timestamp_seconds
```

Two design points here matter more than the metric names:

**A backup can succeed and still be unrestorable.** Collapsing backup and
restore into a single "backups healthy" indicator hides exactly the failure that
costs the most. They are tracked independently and alerted on independently.

**Metrics are published on failure too.** The scripts write their metrics from
an `EXIT` trap, so a failed run still publishes. If a failing job simply stopped
writing, its series would go stale and then absent, and an alert whose series has
disappeared never fires. The last-success timestamp is held in a separate state
file so a failed run can report the true previous value rather than clearing it.

## Alert routing

Alertmanager groups by `alertname` and `instance`, waits 30s to batch, and
repeats every 4 hours for warnings and every hour for critical.

Delivery goes to `alert-sink`, a small standard-library webhook receiver on
loopback that appends every notification to a log file. Alertmanager's own UI
shows what is firing now; an incident record needs to know what fired and when,
and that requires a log.

A `NodeDown` alert inhibits every other alert for the same instance. A host that
is off will also trip its disk, service and probe checks, and the useful
notification is the cause rather than its six consequences.

Email and chat were considered and rejected: both need credentials or internet
access this isolated lab does not have, and neither demonstrates anything the
webhook path does not.

## Exposure of the monitoring stack itself

Monitoring tools get deployed as though they were harmless. They are not:

- **Prometheus** has no authentication. Its metrics are a detailed inventory of
  every host, and the lifecycle endpoint reloads configuration on request.
- **Alertmanager** has no authentication. Anyone who reaches it can create a
  silence, and a silenced alert is indistinguishable from no incident.
- **Blackbox exporter** is a request proxy by design. `/probe?target=` connects
  to whatever it is given, so an exposed instance is a usable pivot into the
  internal network.

Accordingly, blackbox and alert-sink listen on loopback only, Prometheus and
Alertmanager are confined to the lab segment which has no route to the internet,
and windows_exporter's firewall rule on DC01 permits only MON01's address.

This is network placement, not authentication. In production all of these would
sit behind an authenticating reverse proxy. Stated plainly rather than implied to
be equivalent.

## Known gaps

- **Single monitoring host.** If MON01 is down, nothing is watching and nothing
  reports that fact. The DC01 health check runs independently, which partially
  covers it. Production needs redundant collection and an external dead-man
  check.
- **No long-term metric storage.** Local retention only.
- **No end-to-end authentication check.** `dcdiag` on DC01 covers directory
  health, but nothing attempts an actual Kerberos authentication from a third
  host, which is what a user experiences.
- **Time offset is not alerted on.** windows_exporter's `time` collector exposes
  it; no rule consumes it yet. Clock skew past the Kerberos tolerance breaks
  authentication in a way that presents as a permissions problem.
