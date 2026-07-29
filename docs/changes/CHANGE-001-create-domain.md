# CHANGE-001 — Create the lab.local domain

| Field | Value |
|---|---|
| Date | _to be recorded_ |
| Implemented by | Ali |
| Category | Standard — planned build |
| Risk | Low — greenfield, no existing service affected |
| Affected systems | DC01 |
| Downtime | None; nothing was in service |

## Reason

The lab needs a directory service to authenticate clients, a DNS server for the
segment, and DHCP so clients can be added without hand-configuring addresses. A
single Windows Server host provides all three.

## What changed

1. Promoted DC01 to a new forest, `lab.local`, NetBIOS `LAB`.
2. Installed DNS as part of promotion.
3. Installed and authorised DHCP.
4. Created the OU structure `Company > {Computers, Employees, Groups}`.
5. Created the user `ali` and the global security group `IT-Team`.
6. Created the `CompanyShare` file share at `C:\CompanyShare`.

## Risk assessment

| Risk | Mitigation |
|---|---|
| DHCP scope conflicts with VMware's own DHCP | VMware DHCP was disabled on VMnet2 before this change |
| Domain name collides with something else | Isolated network with no route out. See the note below |
| Default share permissions too permissive | Not addressed here — became CHANGE-004 |

## Known issue accepted at the time

The domain was created as `lab.local`. `.local` is reserved for multicast DNS,
and a name under `.test` would have been the correct choice. This was not caught
before promotion. Renaming an Active Directory domain in practice means
rebuilding the forest, so it was accepted and documented rather than corrected.

Recorded in [`docs/risks.md`](../risks.md) with the full reasoning. It is the
clearest example in this project of a decision that is free before deployment
and expensive afterwards.

## Rollback

Revert DC01 to the pre-promotion VM snapshot. Nothing depended on the domain at
this point. Beyond it, demotion via `Uninstall-ADDSDomainController` would be
required.

## Verification

| Check | Expected |
|---|---|
| `Get-ADDomain` | `DNSRoot = lab.local`, `NetBIOSName = LAB` |
| `dcdiag /test:DNS` | passed |
| `Get-Service NTDS, DNS, DHCPServer, Netlogon` | all Running |
| `Get-DhcpServerInDC` | DC01 listed as authorised |

## Outcome

Completed. The `.local` naming issue was identified after the fact and accepted.
