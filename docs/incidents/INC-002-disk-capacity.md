# INC-002 — Disk capacity exhausted on DC01

| Field | Value |
|---|---|
| Date | 2026-07-30 |
| Detected at | 08:34:50 UTC (`WindowsDiskSpaceLow` began firing; delivered to alert-sink 08:35:20) |
| Resolved at | 08:50:20 UTC (resolution delivered to alert-sink) |
| Duration | ~16 minutes |
| Severity | Major |
| Affected systems | DC01 |
| Detected by | `WindowsDiskSpaceLow` |
| Simulated | Yes, deliberate exercise |

## Summary

`E:`, a non-system volume on DC01, was filled with dummy files past the 85%
warning threshold to confirm `WindowsDiskSpaceLow` fires correctly. `C:` — the
system volume — was never touched. The critical (95%) threshold was not crossed
in this run; only the warning path was exercised.

## Detection

`WindowsDiskSpaceLow` fired once usage on `E:` crossed 85% for the required
`for: 5m` window.

Confirmed from the alert-sink delivery log on MON01
(`screenshots/monitoring/07-alert-sink-log.png`): `WindowsDiskSpaceLow` fired
for `192.168.56.10:9182` with summary "Volume E: is over 85% full",
`startsAt` 08:34:50 UTC, delivered 08:35:20; its resolution was delivered at
08:50:20. The gap between the fill crossing 85% and the alert firing includes
the rule's deliberate `for: 5m` window.

## Timeline

| Time (UTC) | Event |
|---|---|
| ~08:29 | `fsutil file createnew E:\fill-01.bin ...` — usage crossed 85%, `WindowsDiskSpaceLow` entered pending |
| 08:34:50 | `WindowsDiskSpaceLow` fired after the 5m window; delivered to alert-sink 08:35:20 |
| ~08:45 | Fill files removed |
| 08:50:20 | Resolution delivered to alert-sink |

## Investigation

The volume and method were chosen deliberately before starting, not discovered
mid-exercise:

| Decision | Reason |
|---|---|
| Filled `E:`, not `C:` | A full system volume on a domain controller can damage the AD database. `E:` isolates the exercise from anything the directory depends on. |
| Used `fsutil file createnew` | Creates a file of an exact size instantly, without writing real data, so usage can be pushed to a precise percentage rather than approximated. |
| Stopped at 85%, did not force 95% | The warning path was the target of this run. The critical threshold uses a shorter `for:` window (2m vs 5m) and is otherwise identical logic — crossing it was not expected to reveal anything the warning alert did not already show. |

```powershell
Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='E:'" |
    Select-Object DeviceID, @{n='FreeGB';e={[math]::Round($_.FreeSpace/1GB,2)}}
```

## Root cause

Deliberately introduced: dummy files created to exceed 85% usage on `E:`. In an
unplanned occurrence the cause would be whatever process or dataset is
consuming the volume — this exercise validates detection, not a real capacity
event.

## Resolution

```powershell
Remove-Item E:\fill-01.bin, E:\fill-02.bin -Force
Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='E:'" |
    Select-Object DeviceID, @{n='FreeGB';e={[math]::Round($_.FreeSpace/1GB,2)}}
```

_fill in: confirm `WindowsDiskSpaceLow` resolved in Alertmanager after cleanup,
rather than assuming it did._

## Prevention

Already in place and validated by this exercise:

| Measure | Detail |
|---|---|
| `WindowsDiskSpaceLow` | 85%, `for: 5m` — confirmed firing correctly in this run |
| `WindowsDiskSpaceCritical` | 95%, `for: 2m` — rule exists, **not yet exercised**; see below |

## What this exercise revealed

1. **The threshold and the volume both worked as designed.** `E:` filled and
   alerted without any risk to the directory service — the isolation decision
   made before starting held up.
2. **The critical threshold remains unvalidated.** `WindowsDiskSpaceCritical`
   has never actually fired in this lab. It shares the same expression pattern
   as the warning rule, evaluated at 95% with a shorter window, so the risk of
   it being subtly wrong is low — but "low risk" and "confirmed" are different
   claims, and only the second one is true of the warning rule after this
   exercise.
3. **A precise, disposable volume is a reliable way to rehearse a disk alert**
   without any of the ambiguity of filling a shared or system volume.

## Optional follow-up

Cross 95% in a future run — `fsutil file createnew` one more file on `E:` after
the warning alert is confirmed and cleared — to validate
`WindowsDiskSpaceCritical` the same way this exercise validated the warning
rule. Not required to close this incident; recorded so it is a deliberate
decision rather than an oversight.

## Related

[`docs/runbooks/disk-full.md`](../runbooks/disk-full.md)
