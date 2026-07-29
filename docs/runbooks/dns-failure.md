# Runbook — DNS resolution failure

**When:** `DNSProbeFailed` or `WindowsServiceDown{name="DNS"}` fires, or users
report authentication, Group Policy or domain join problems.

**Time:** 5–15 minutes.
**Access:** administrator on DC01.

Derived from INC-001. Read that record before working through this the first
time — the failure does not look the way you expect.

## 1. Do not trust a single test

The trap this runbook exists for: **ping and short-name access keep working
while DNS is completely down.** Windows falls back to NetBIOS and LLMNR for
single-label names, so `\\DC01\CompanyShare` resolves on the local segment
without any DNS server at all.

Test several paths and compare:

```powershell
ping 192.168.56.10                      # host reachable?
ping dc01                               # short name — may work via NetBIOS
nslookup dc01.lab.local 192.168.56.10   # the real test
nslookup lab.local 192.168.56.10
```

| Pattern | Means |
|---|---|
| All fail | Host or network problem, not DNS. Different runbook. |
| Ping works, FQDN lookup fails | DNS service problem. Continue here. |
| Everything works | Check whether the client is resolving via a cached answer, or against a different server. |

## 2. Check the service on DC01

```powershell
Get-Service DNS, NTDS, Netlogon | Format-Table Name, Status, StartType
Get-DnsServerZone
```

A `Running` status is not sufficient. A DNS service that is running but not
answering for its zone is the exact condition INC-001 covered.

```powershell
Resolve-DnsName lab.local -Server 127.0.0.1 -Type SOA
```

## 3. If the service is stopped

```powershell
Start-Service DNS
Get-Service DNS
```

Then find out **why** it stopped rather than declaring it fixed:

```powershell
Get-WinEvent -LogName System -MaxEvents 50 |
    Where-Object { $_.ProviderName -match 'DNS|Service Control Manager' } |
    Format-Table TimeCreated, Id, LevelDisplayName, Message -AutoSize -Wrap
```

## 4. If the service is running but not answering

```powershell
dcdiag /test:DNS
Get-DnsServerZone | Format-Table ZoneName, ZoneType, IsDsIntegrated
Get-DnsServerForwarder
```

Restart and re-test:

```powershell
Restart-Service DNS
Resolve-DnsName dc01.lab.local -Server 127.0.0.1
```

## 5. Clear caches before believing it is fixed

Stale negative cache entries make a fixed server look broken.

On DC01:

```powershell
Clear-DnsServerCache -Force
```

On affected clients:

```powershell
ipconfig /flushdns
nslookup dc01.lab.local
```

## 6. Verify properly

Fixed means the fully qualified path works, not that the service shows Running:

```powershell
nslookup dc01.lab.local
Resolve-DnsName -Name '_ldap._tcp.dc._msdcs.lab.local' -Type SRV
nltest /dsgetdc:lab.local
Test-Path \\dc01.lab.local\CompanyShare
```

The SRV record is how a Windows client finds a domain controller. If it does not
resolve, domain functionality is still broken however healthy the service looks.

On MON01, confirm the probe recovered:

```bash
curl -s 'localhost:9115/probe?target=192.168.56.10&module=dns_soa' | grep '^probe_success'
```

Expect `probe_success 1`, and `DNSProbeFailed` resolved in Alertmanager.

## 7. Confirm recovery actions are still configured

```powershell
sc.exe qfailure DNS
```

Should show restart actions. If not:

```powershell
sc.exe failure DNS reset= 86400 actions= restart/60000/restart/60000/restart/60000
```

The daily health check on DC01 also verifies this, so a `WARN` on
"DNS failure recovery" in the report means it has been reset.

## What is expected to still work during a DNS outage

Stating this prevents both over- and under-estimating the impact:

| Still works | Reason |
|---|---|
| Existing logged-on sessions | Kerberos tickets valid until expiry |
| Short-name share access | NetBIOS/LLMNR fallback on the local segment |
| Access by IP address | No name resolution involved |
| Recently resolved names | Client-side DNS cache |

| Fails |
|---|
| Domain controller discovery (`_ldap._tcp` SRV lookups) |
| New authentication and domain joins |
| Group Policy refresh |
| Anything using a fully qualified name |
