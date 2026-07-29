# VMware Hands-on Labs — notes

> **STATUS: not yet completed.** Outlines only. Replace each with real notes
> after working through the labs.

## Why these exist

This lab runs on VMware Workstation, a type-2 hypervisor on a laptop. Real
datacenter virtualisation runs ESXi and vCenter, which will not fit in 16 GB of
RAM alongside four VMs.

Rather than claim experience that does not exist, the gap is closed with
VMware's free browser-based [Hands-on Labs](https://labs.hol.vmware.com/), which
run genuine vSphere against real infrastructure, and the notes are written as a
**comparison** rather than a lab transcript.

## The rule for writing these up

For each concept, answer three things:

1. What the lab covered
2. How it maps to what was built here in Workstation
3. **Where the two genuinely differ**

And state plainly which parts were performed hands-on versus read about. Being
straightforward about the boundary of your experience is far stronger in an
interview than a claim that does not survive one follow-up question — and it
will get a follow-up question.

## Planned writeups

| File | Covers |
|---|---|
| `vsphere-basics.md` | ESXi, vCenter, clusters, HA, DRS, vMotion, datastores |
| `vmware-networking.md` | Standard and distributed switches, port groups, VLANs, uplinks |

## vsphere-basics.md — outline

- **Type-1 versus type-2.** ESXi runs on bare metal; Workstation runs on top of
  Windows 11. What that changes about resource scheduling, overhead and
  isolation.
- **vCenter as a management plane.** What it provides that standalone hosts do
  not: centralised inventory, permissions, templates, and the features below,
  none of which work without it.
- **Clusters, HA and DRS.** This lab has none. A DC01 failure means no
  authentication, no DNS and no DHCP until it is manually recovered — the risk
  recorded first in `docs/risks.md`. HA is the mechanism that removes it.
- **vMotion.** Why live migration needs shared storage and a dedicated network,
  and why a single laptop with local disks cannot do it.
- **Datastores and shared storage.** Against the local VMDKs used here.
- **Snapshots versus backups.** vSphere makes the same distinction as
  `docs/backup-policy.md`, for the same reasons. Worth restating in VMware's
  own terms, since it is the point most often confused in practice.

## vmware-networking.md — outline

- **Standard versus distributed switches.** What a vDS gives you that per-host
  configuration does not.
- **Port groups and VLANs.** Map to Workstation's VMnet concept: `VMnet2`
  host-only corresponds roughly to an isolated port group with no uplink; NAT
  corresponds to a port group behind an address-translating gateway.
- **Uplinks and teaming.** Absent here — a single virtual adapter per VM.
- **Why DHCP was disabled on VMnet2.** The same class of decision as controlling
  which DHCP server serves a port group in a real environment. Two DHCP servers
  on one broadcast domain produce intermittent wrong-subnet leases that present
  as random network flakiness rather than as a configuration error.
- **Isolation as a security control.** The lab segment has no route out, and the
  NAT adapters were disconnected after setup. The vSphere equivalent, and where
  that stops being sufficient.
