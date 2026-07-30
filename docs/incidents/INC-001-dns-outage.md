# INC-001 — DNS service stopped on DC01, masked by NetBIOS name resolution

| Field | Value |
|---|---|
| Date | 2026-07-29 |
| Detected at | Not recorded — this exercise predates the alert-sink delivery log, and nothing was timestamping alerts because nothing was alerting. That absence is the incident's central finding |
| Resolved at | Not recorded |
| Duration | Minutes — the fault was deliberately introduced and immediately investigated |
| Severity | Major — degraded, not total |
| Affected systems | DC01, CLIENT01 |
| Detected by | Manual observation. **Monitoring did not detect it** — see below |
| Simulated | Yes, deliberate exercise |

## Summary

The DNS Server service was stopped on DC01 to test whether the lab's monitoring
and troubleshooting procedures would catch a name resolution outage. It did not
present as an outage from the outside: ICMP still answered and short-name access
to the file share continued to work through NetBIOS/LLMNR fallback. Only fully
qualified lookups failed. The service was restarted and configured with recovery
actions so it restarts itself on future failures.

## Detection

**Nothing alerted.** At the time of the exercise the lab had no blackbox DNS
probe and no windows_exporter, so no automated check was watching the DNS
service at all. The outage was found because it had been deliberately caused.

This is the most useful result the exercise produced. Had this happened
unannounced, the first signal would have been a user unable to authenticate,
which is discovery by complaint rather than by monitoring.

## Timeline

Clock times were not recorded — no alerting existed yet to timestamp anything,
which is precisely what this exercise exposed. The sequence is preserved in
order:

| # | Event |
|---|---|
| 1 | `Stop-Service DNS` on DC01 |
| 2 | `ping dc01` from CLIENT01 — still succeeded |
| 3 | `nslookup dc01.lab.local` — timed out |
| 4 | `\\DC01\CompanyShare` by IP — worked |
| 5 | `\\DC01\CompanyShare` by short name — worked, unexpectedly |
| 6 | `\\dc01.lab.local\CompanyShare` by FQDN — failed |
| 7 | `Start-Service DNS` + `ipconfig /flushdns` |
| 8 | Resolution confirmed restored |
| 9 | Service recovery actions configured |

## Investigation

The differential was the whole point: testing several access paths separately
rather than concluding from one failure.

| Test | Result | What it ruled out |
|---|---|---|
| `ping 192.168.56.10` | Success | Not a network or host outage |
| `ping dc01` | Success | Name resolution was not fully broken |
| `nslookup dc01.lab.local` | Timeout | DNS service itself not answering |
| Share access by IP | Success | SMB and authentication intact |
| Share access by short name | **Success** | Something other than DNS was resolving the name |
| Share access by FQDN | Failure | Confirmed DNS as the failing component |

The short name continuing to work is the finding. Windows does not rely on DNS
alone: when a DNS lookup fails for a single-label name, it falls back to
NetBIOS-over-TCP/IP and LLMNR, both of which resolve on the local segment without
a DNS server. Everyday access by `\\DC01\...` therefore kept working while the
directory's own DNS was completely down.

The practical consequence is that a partial DNS failure looks like nothing is
wrong until something needs a fully qualified name — domain controller discovery,
Kerberos service tickets, Group Policy, or any newly authenticating client.

## Root cause

The DNS Server service was stopped, deliberately, as the exercise. In an
unplanned occurrence the equivalent causes would be a service crash, a failed
start after patching, or a dependency failure at boot.

The contributing cause worth recording is not why DNS stopped but why nothing
noticed: no check existed that asked DNS a question. Reachability checks and
short-name access both passed throughout.

## Resolution

```powershell
Start-Service DNS
ipconfig /flushdns          # on CLIENT01
```

Verified by resolving the FQDN and accessing the share by fully qualified name,
not merely by confirming the service showed as Running. A service in the Running
state that is not answering queries is exactly the condition this incident is
about.

## Prevention

Implemented:

| Measure | Detail |
|---|---|
| Service recovery | DNS configured to restart on first, second and subsequent failure, 1 minute delay |
| Recovery verified on an ongoing basis | `Invoke-HealthCheck.ps1` checks `sc.exe qfailure DNS` daily and warns if the restart action is missing, because a setting nobody verifies quietly gets lost |
| Blackbox DNS probe | `dns_soa` module queries DC01 for the `lab.local` SOA record and requires `NOERROR`. Fails immediately when the server is not answering for its zone |
| `DNSProbeFailed` alert | Fires after 3 minutes, severity critical |
| `WindowsServiceDown` alert | Watches NTDS, DNS, DHCPServer and Netlogon via windows_exporter, fires after 2 minutes |

Deliberately **not** relied upon: a TCP probe against port 53. It proves
something is bound to the port, which was never the failing condition here.

Still open: nothing performs an end-to-end authentication test from a third host,
which is the check that would most closely reflect what a user experiences.
Recorded in `monitoring-policy.md` under known gaps.

## What this exercise revealed

1. **Reachability is not availability.** ICMP answered for the entire outage.
   Any check built on ping alone would have reported the domain controller as
   healthy throughout.

2. **Name resolution has fallback paths that hide the failure of the one you
   meant to use.** NetBIOS and LLMNR kept short names working. This is
   convenient in normal operation and actively misleading during a fault.

3. **The failure was partial, and describing it as total would be wrong.**
   Existing sessions kept working — cached DNS answers, unexpired Kerberos
   tickets, and cached credentials all contribute. The accurate statement is
   that *domain controller discovery and new authentication* fail, not that
   everything stops.

4. **Testing one access path would have produced the wrong conclusion.** Had
   only the short name been tested, the verdict would have been "DNS is fine".

## Related

- `docs/runbooks/dns-failure.md` — procedure derived from this incident
- `docs/risks.md` — the `.local` domain naming deviation, which comes from the
  same area: name resolution on a Windows network has more moving parts than it
  appears to
