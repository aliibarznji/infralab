# INC-004 — Authentication fails from clock skew

> **STATUS: PLANNED — not yet performed.** This is the pre-flight plan. Replace
> this banner with the real record once the exercise has run, using
> [`TEMPLATE.md`](TEMPLATE.md) for the section order.

| Field | Value |
|---|---|
| Date | _to be recorded_ |
| Severity | Major |
| Affected systems | CLIENT01 |
| Expected detection | **None.** Time offset is not currently alerted on |
| Simulated | Yes |

## Safety — skew the client, not the domain controller

**Change CLIENT01's clock. Do not change DC01's.**

DC01 holds the PDC Emulator FSMO role and is the authoritative time source for
the entire domain. Skewing it propagates to every domain member, and unwinding
that is considerably more work than the exercise is worth. Skewing the client
produces an identical Kerberos failure and reverts cleanly.

Take a VM snapshot of CLIENT01 named `before-INC-004` first.

## Background

Kerberos uses timestamps to prevent replay attacks, so it requires the client
and the KDC to agree on the time within a tolerance — five minutes by default.
Beyond that, the KDC rejects the authentication attempt outright.

The reason this is worth exercising is that **the symptom does not look like a
clock problem.** It presents as access denied, which sends people to check
permissions and group membership. Recognising the real cause quickly is the
skill being practised.

## Method

Run CLIENT01 with BKP01 shut down to stay inside the RAM budget.

```powershell
# On CLIENT01, as administrator. Record the starting state first.
w32tm /query /status
w32tm /query /source

Stop-Service w32time
Set-Date (Get-Date).AddMinutes(10)
Get-Date
```

Force a fresh authentication — cached tickets keep working until they expire, so
without purging them nothing appears to break:

```powershell
klist purge
klist
net use \\DC01\CompanyShare /delete
net use \\dc01.lab.local\CompanyShare
gpupdate /force
```

## What to record

- The exact error text returned
- Security event log entries on **both** CLIENT01 and DC01 — the DC side shows
  the rejection reason, which is where the real diagnosis is
- Whether anything at all in monitoring reflected the problem
- How long it took to identify the cause, and what was checked first

```powershell
Get-WinEvent -LogName Security -MaxEvents 40 |
    Where-Object { $_.Id -in 4768, 4769, 4771 } |
    Format-Table TimeCreated, Id, Message -AutoSize -Wrap
```

## Resolution

```powershell
Start-Service w32time
w32tm /resync /force
w32tm /query /status
klist purge
net use \\dc01.lab.local\CompanyShare
```

If resync fails, re-point the client at the domain hierarchy explicitly:

```powershell
w32tm /config /syncfromflags:domhier /update
Restart-Service w32time
w32tm /resync /force
```

## The gap this is meant to expose

Nothing alerts on clock offset today. `windows_exporter`'s `time` collector is
already enabled and exposes the offset, so closing the gap means adding a rule
rather than deploying anything:

```yaml
      - alert: ClockSkewHigh
        expr: abs(windows_time_computed_time_offset_seconds) > 120
        for: 5m
        labels:
          severity: warning
        annotations:
          summary: "Clock on {{ $labels.instance }} is more than 2 minutes from its time source"
          description: "Kerberos rejects authentication beyond roughly 5 minutes of skew, and the resulting failure presents as access denied rather than as a time problem. Alerting at 2 minutes gives room to correct it first."
```

Verify the metric name against a live scrape before adding the rule — collector
metric names change between windows_exporter versions:

```bash
curl -s 192.168.56.10:9182/metrics | grep -i time_ | head
```

Adding this rule is a legitimate outcome of the exercise and should be its own
commit, so the improvement is traceable to the incident that motivated it.

## Questions the writeup should answer

- How long before the failure would have been diagnosed correctly without
  knowing the cause in advance?
- Which false leads did the symptom suggest — permissions, group membership,
  the recent ACL changes?
- Does the new rule's threshold leave enough margin before the Kerberos limit?

## Related

[`docs/monitoring-policy.md`](../monitoring-policy.md) — known gaps
