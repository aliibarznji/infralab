# CHANGE-002 — Deploy monitoring on MON01

| Field | Value |
|---|---|
| Date | _to be recorded_ |
| Implemented by | Ali |
| Category | Standard |
| Risk | Low — read-only observation, no change to DC01 |
| Affected systems | MON01 |
| Downtime | None |

## Reason

No visibility into any host. Failures were discoverable only by noticing them,
which INC-001 later demonstrated does not work: a stopped DNS service was
invisible to every check that existed at the time.

## What changed

1. Built MON01 on Ubuntu 26.04, static `192.168.56.20`.
2. Installed Prometheus 3.13.1, Grafana 13.1.1 and node_exporter as native
   systemd services.
3. Imported the *Node Exporter Full* community dashboard (Grafana ID 1860).
4. Added `/usr/local/bin/health-check.sh`, hourly via cron, covering ICMP to
   DC01 and BKP01, DNS resolution of `dc01.lab.local`, systemd unit state, and
   root filesystem usage above 80%.
5. Removed the NAT adapter so MON01 sits only on VMnet2.

## Risk assessment

| Risk | Mitigation |
|---|---|
| Monitoring services exposed without authentication | Isolated segment with no route to the internet; see `monitoring-policy.md` |
| Scrape load on monitored hosts | 30s interval, trivial at this scale |
| Health check reporting false results | Materialised — see below |

## Issue found during implementation

The first health check run reported `FAIL service node_exporter`. The service was
healthy; the packaged systemd unit is named `prometheus-node-exporter`, and the
check was looking for the wrong name.

The script was corrected rather than the result dismissed. A monitoring check
that reports a false failure is a real defect: alert fatigue is how genuine
alerts come to be ignored.

## Rollback

`systemctl disable --now prometheus grafana-server prometheus-node-exporter`.
Nothing outside MON01 is affected.

## Verification

| Check | Expected |
|---|---|
| `systemctl is-active prometheus grafana-server prometheus-node-exporter` | all active |
| Grafana dashboard 1860 | live CPU, memory, disk, network data |
| `/var/log/health-check.log` | all checks OK |

## Outcome

Completed. Alerting was **not** included in this change — Prometheus was
collecting and graphing but not alerting, which is why INC-001 went undetected.
Closed by CHANGE-005.
