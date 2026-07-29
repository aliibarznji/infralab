# Runbook — DC01 will not boot

**When:** the domain controller fails to start, or starts but Active Directory
services do not.

**Time:** 20 minutes to several hours depending on the path taken.
**Access:** VMware Workstation console, DSRM password.

With a single domain controller there is no failover. While DC01 is down there
is no authentication, no DNS and no DHCP for the lab. This is the risk recorded
first in `docs/risks.md`, and this runbook is what "documented recovery" means.

**Have the DSRM password before you start.** It was set during promotion and is
in the password manager. Without it, options 2 and 3 below are unavailable.

## 1. Establish what kind of failure this is

| Symptom | Likely area |
|---|---|
| No POST, no boot device | Virtual disk or VM configuration |
| Boots to recovery / repair loop | Filesystem or boot record |
| Boots to login, AD services fail | Directory database or SYSVOL |
| Boots and services run, nothing resolves | Not this runbook — see `dns-failure.md` |

Check the VM configuration before assuming guest damage: a disconnected virtual
disk or a snapshot chain problem presents as a boot failure but is repaired in
Workstation, not in Windows.

## 2. Fastest path — revert to a VM snapshot

For a lab this is almost always the right first move, and it is what the
snapshots exist for.

```
VMware Workstation → VM → Snapshot → Snapshot Manager → select → Go To
```

**What you lose:** every change since the snapshot, including directory changes,
DHCP leases and anything written to `CompanyShare` after that point.

**What protects the share:** `CompanyShare` is backed up independently to BKP01.
After reverting, restore any files created since the snapshot using
`restore-file.md`. Check the snapshot count and last-success timestamp first:

```bash
sudo -i
export RESTIC_REPOSITORY=/var/backups/restic-repo
export RESTIC_PASSWORD_FILE=/etc/restic-pass
restic snapshots --tag dc01-share
```

**What is not protected:** the AD database itself is only covered by VM
snapshots. Recorded as a known gap in `backup-policy.md`.

## 3. Directory Services Restore Mode

Use when Windows boots but AD DS will not start, and you want to repair rather
than revert.

Boot into DSRM:

```
At boot: F8 → Directory Services Restore Mode
```

or from a working session:

```powershell
bcdedit /set safeboot dsrepair
shutdown -r -t 0
```

Log in as `.\Administrator` with the **DSRM** password — a local account, not
the domain administrator.

Check the database:

```
ntdsutil
  activate instance ntds
  files
    integrity
    recover
  quit
quit
```

Return to normal boot — do not skip this, or the machine stays in DSRM:

```powershell
bcdedit /deletevalue safeboot
shutdown -r -t 0
```

## 4. Verify recovery properly

Do not stop at "it booted".

```powershell
Get-Service NTDS, DNS, DHCPServer, Netlogon | Format-Table Name, Status
dcdiag /test:DNS
Get-ADDomain | Select-Object DNSRoot, NetBIOSName
Get-SmbShare | Where-Object Name -in 'SYSVOL','NETLOGON','CompanyShare'
Get-DhcpServerv4Scope
```

Then run the health check, which covers all of this plus the share ACL and the
DNS recovery configuration:

```powershell
C:\Scripts\Invoke-HealthCheck.ps1 -OutputPath C:\HealthChecks
```

From CLIENT01, confirm the domain works from a user's perspective — the only
test that actually matters:

```powershell
nltest /dsgetdc:lab.local
Test-ComputerSecureChannel -Verbose
Test-Path \\dc01.lab.local\CompanyShare
```

On MON01, confirm monitoring recovered:

```bash
curl -s 'localhost:9090/api/v1/query?query=up{job="windows"}' |
  python3 -c 'import json,sys; print(json.load(sys.stdin)["data"]["result"])'
```

## 5. If the directory cannot be recovered

With one domain controller and no system state backup, the remaining path is to
rebuild: promote a fresh forest, recreate the OU structure, accounts and group
from `docs/inventory.md`, recreate the share and its ACLs from
`backup-policy.md`, then restore the share contents from restic.

Client machines will need to rejoin — their computer accounts exist only in the
directory that was lost.

That this is the fallback is the argument for a second domain controller, and it
belongs in the incident record if this path is ever taken.

## 6. Afterwards

Write the incident record, and take a fresh snapshot once the machine is
verified healthy — the old one is now the only rollback point and it is older
than it was.
