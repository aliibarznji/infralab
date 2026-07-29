# Sample reports

> **STATUS: to be added.**

Real output from the lab's scheduled jobs, committed so the repository shows
results without needing the lab running.

## What to add

| File | Source |
|---|---|
| `health-check-sample.html` | One run of `Invoke-HealthCheck.ps1` on DC01 |
| `health-check-log-sample.txt` | A few hours of `/var/log/health-check.log` from MON01 |

## Generating the Windows report

```powershell
C:\Scripts\Invoke-HealthCheck.ps1 -OutputPath C:\HealthChecks
```

Pick a run where the system was healthy, or one with a genuine `WARN` if it
illustrates something worth showing. Do not hand-edit the HTML — a fabricated
report is worth less than no report, and the point of committing one is that it
is real output.

## Before committing

The report embeds event log detail, which can include usernames, file paths and
machine names. Read it through before adding it. The script HTML-encodes those
fields so they render as text rather than markup, but encoding prevents
injection, not disclosure.
