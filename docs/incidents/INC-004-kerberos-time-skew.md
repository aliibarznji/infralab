# INC-004 — Clock skew on CLIENT01, and an unresolved observation about Kerberos tolerance

> Unlike the other incident records, this one ends without a fully confirmed
> root cause — that is the honest result and is documented as such rather than
> papered over.

| Field | Value |
|---|---|
| Date | 2026-07-30 |
| Severity | Major |
| Affected systems | CLIENT01 |
| Expected detection | None at the time of the exercise — see Prevention |
| Simulated | Yes |

## Summary

CLIENT01's clock was skewed forward and Kerberos tickets purged to force a fresh
authentication. The domain's Kerberos `MaxClockSkew` policy was confirmed at 5
minutes, but a reconnection to `\\dc01.lab.local\CompanyShare` **succeeded**
despite roughly 19 minutes of measured skew. Investigation ruled out several
obvious explanations without conclusively identifying the real one. Time was
restored and normal operation confirmed. A `ClockSkewHigh` alert was added
afterward, using the closest metric this windows_exporter build actually
exposes — which is not a direct measurement of drift.

## Safety

The exercise skewed **CLIENT01's** clock, not DC01's. DC01 holds the PDC
Emulator role and is the domain's authoritative time source; skewing it would
have cascaded to every domain member. This constraint was respected throughout.

## Method and observations

```powershell
w32tm /query /status                      # baseline: synced to dc01.lab.local
net stop w32time                          # required an elevated prompt as lab\administrator
Set-Date (Get-Date).AddMinutes(10)
klist purge
net use \\dc01.lab.local\CompanyShare
```

The reconnection **succeeded**. `w32tm /query /status`, checked afterward, showed
roughly 19 minutes of skew rather than the 10 minutes originally set.

### The 10-versus-19-minute gap is not itself the mystery

Once the clock is shifted, it continues running forward from the shifted
baseline. Time spent investigating between the shift and the actual `net use`
attempt — checking VMware Tools time sync (not installed), confirming
`w32time` was genuinely stopped, and later reviewing the DC's Security log —
adds directly to the measured skew at the moment access was finally attempted.
Roughly nine minutes of investigation between the shift and the successful
reconnect would fully account for the difference.

Not recorded: the exact `Get-Date` output immediately before the successful
`net use`, versus immediately after `Set-Date`, would confirm this arithmetic.
A minor bookkeeping point, separate from the real question below.

### The real open question: why did Kerberos tolerate it at all

`MaxClockSkew` was confirmed at 5 minutes via `secedit /export` on DC01. Neither
10 minutes nor 19 minutes should have been within tolerance, yet:

- DC01 Security event log entries for 4768 (TGT request) and 4769 (service
  ticket request) around this period all showed `Failure Code: 0x0` — success.
  No `0x25` (clock skew too great) failures were observed.
- `w32time` was confirmed stopped throughout the skewed window.
- VMware Tools, which can otherwise silently re-correct guest time, was
  confirmed not installed.

This was investigated but **not conclusively resolved**. Recorded as an
observation rather than a finding, which is the correct call — asserting a
cause that was not actually confirmed would be worse than leaving the question
open.

### Candidate explanations, none confirmed

Listed as leads for anyone picking this back up, not as an answer:

1. **An existing, still-valid ticket was reused rather than a fresh one being
   issued at the skewed moment.** Kerberos checks clock skew primarily when a
   ticket is first requested (the AS-REQ / TGS-REQ pre-authentication
   timestamp), not necessarily every time an already-valid ticket is used to
   establish a new session. `klist purge` clears the visible ticket cache for
   the current logon session, but if a different logon context (for example,
   the machine account, or a background service holding its own session) held
   a ticket obtained *before* the clock was shifted, that ticket's own validity
   window would still cover the access — no skew check would apply. **The
   distinguishing test:** compare the exact `TimeCreated` of the successful
   4768/4769 events against the exact moment `net use` was run. A ticket issued
   *after* the skew was introduced and still accepted would be the more
   interesting and harder-to-explain result; a ticket issued *before* the skew
   would resolve this cleanly and mean the skew was simply never tested.

2. **The effective KDC policy differs from what `secedit /export` reports.**
   `secedit /export` reads the security database populated by the last applied
   Default Domain Policy. Kerberos policy is read by the KDC service (`kdcsvc`)
   at points that do not necessarily coincide with every `secedit` read, so the
   configured value and the value the KDC was actually enforcing at the moment
   of the test are not guaranteed to be the same thing.

3. **A background time-correction path other than VMware Tools.** VMware Tools
   was confirmed absent, but that does not rule out every mechanism by which
   the guest's effective time could have been influenced — this was not
   exhaustively tested beyond checking `w32time`'s own state.

None of these were verified before time was restored, so none can be stated as
the cause. If revisited, checking the 4768/4769 timestamps against the `net
use` timestamp (candidate 1) is the cheapest test and the one most likely to
either resolve or substantially narrow the question.

## Resolution

```powershell
net stop w32time
net start w32time
w32tm /resync /force
w32tm /query /status                      # confirmed synced, no warning
klist purge
net use \\dc01.lab.local\CompanyShare      # succeeded normally
```

## Prevention

**Not previously monitored at all.** Before this exercise, nothing in this lab
watched clock offset, and the exercise itself demonstrates why that mattered:
the failure this incident was designed to produce did not present as a time
problem — it did not present as a failure at all.

`ClockSkewHigh` was added afterward:

```yaml
- alert: ClockSkewHigh
  expr: windows_time_ntp_round_trip_delay_seconds > 300
  for: 5m
  labels:
    severity: warning
```

**This closes the monitoring gap only partially.** The windows_exporter build in
this lab does not expose a direct clock-offset metric — only
`windows_time_ntp_round_trip_delay_seconds`, the NTP round-trip network delay.
That is a proxy, not a measurement of drift: a slow or congested link could trip
this alert with the clock perfectly correct, and real drift is not guaranteed to
produce a high round-trip time at all. It is recorded as an imperfect
early-warning signal in `docs/monitoring-policy.md`, not represented as solving
the problem it was added for.

Validated with `promtool check rules` (16 rules total) and a unit test asserting
it fires on a sustained high value — the test confirms the *rule* behaves
correctly, not that the underlying metric is a trustworthy skew indicator.

Deployed with `sudo systemctl restart prometheus` — `reload` is not supported by
this packaged unit, a detail worth having in `docs/runbooks/deploy-monitoring.md`
for the next person who tries `reload` first and wonders why nothing changed.

## What this exercise revealed

1. **The intended failure did not occur, and that is itself the finding.**
   INC-004 set out to demonstrate that clock skew breaks Kerberos in a way that
   looks like a permissions problem. Instead it demonstrated something arguably
   more useful: that the actual tolerance of this Kerberos deployment is not
   fully understood, which is a gap worth knowing about independent of whether
   the original failure mode was ever produced.
2. **"Investigated and inconclusive" is a legitimate outcome**, and recording it
   as such is more valuable than forcing a tidy conclusion. A future pass with
   the specific timestamp comparison above would either resolve this or turn it
   into a genuine, reproducible finding about Kerberos ticket reuse.
3. **windows_exporter's available metrics do not always match what a plan
   assumes.** The original INC-004 plan named
   `windows_time_computed_time_offset_seconds` without having confirmed it
   existed. It did not, on this build. The alert was written against what a
   live scrape actually showed, not against the assumption — and the resulting
   alert is honest about being weaker than originally intended as a result.

## Related

[`docs/monitoring-policy.md`](../monitoring-policy.md) — known gaps,
[`docs/risks.md`](../risks.md) — risks closed
