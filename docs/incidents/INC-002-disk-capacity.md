# INC-002 — Disk capacity exhausted

> **STATUS: PLANNED — not yet performed.** This is the pre-flight plan. Replace
> this banner with the real record once the exercise has run, using
> [`TEMPLATE.md`](TEMPLATE.md) for the section order.

| Field | Value |
|---|---|
| Date | _to be recorded_ |
| Severity | Major |
| Affected systems | DC01 (or BKP01) |
| Expected detection | `WindowsDiskSpaceLow` → `WindowsDiskSpaceCritical` |
| Simulated | Yes |

## Safety

**Never fill DC01's system volume.** A full `C:` on a domain controller can
damage the Active Directory database, and recovering from that turns a scripted
exercise into a real rebuild. Use a separate volume.

DC01 in this lab has a single `C:` volume, so either:

- **Preferred:** add a small second virtual disk (5 GB), initialise it as `D:`,
  and fill that. Also gives INC-005 and future exercises somewhere safe.
- **Alternative:** run the exercise on BKP01's root filesystem instead, which
  exercises `DiskSpaceLow` rather than the Windows rules. Less representative of
  the risk on a DC, but zero risk to the directory.

Take a VM snapshot named `before-INC-002` either way.

## Method

Add and initialise the second disk (Workstation → VM → Settings → Add → Hard
Disk, 5 GB), then in Windows:

```powershell
Get-Disk | Where-Object PartitionStyle -eq 'RAW' |
    Initialize-Disk -PartitionStyle GPT -PassThru |
    New-Partition -AssignDriveLetter -UseMaximumSize |
    Format-Volume -FileSystem NTFS -NewFileSystemLabel 'LabData' -Confirm:$false
```

Fill it in stages, so both thresholds are crossed separately and each can be
timed:

```powershell
# ~85% of a 5 GB volume
fsutil file createnew D:\fill-01.bin 4000000000
Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='D:'" |
    Select-Object DeviceID, @{n='FreeGB';e={[math]::Round($_.FreeSpace/1GB,2)}}
```

Wait for `WindowsDiskSpaceLow` to fire, record the time, then push past 95%:

```powershell
fsutil file createnew D:\fill-02.bin 700000000
```

## What to record

- Time the fault was introduced, versus time each alert moved pending → firing
- Whether the observed delay matches the configured `for:` duration (5m and 2m)
- The alert-sink log entry, from `/var/log/alert-sink/alert-sink.log` on MON01
- Whether `WindowsDiskSpaceCritical` correctly superseded the warning, or both
  fired and stayed firing

## Resolution

```powershell
Remove-Item D:\fill-01.bin, D:\fill-02.bin -Force
```

Confirm both alerts resolve in Alertmanager rather than assuming they did.

## Questions the writeup should answer

- Did the 85% threshold give enough warning to act before 95%?
- Is 85% right for a 5 GB volume? It leaves 750 MB, which on a larger volume
  would be generous and here is not. Does the threshold need to be
  size-dependent rather than a flat percentage?
- Would this have been caught without monitoring, and by what?

## Related

[`docs/runbooks/disk-full.md`](../runbooks/disk-full.md)
