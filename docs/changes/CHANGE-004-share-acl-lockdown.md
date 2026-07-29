# CHANGE-004 — Replace Everyone with group-based access on CompanyShare

| Field | Value |
|---|---|
| Date | _to be recorded_ |
| Implemented by | Ali |
| Category | Standard — security remediation |
| Risk | **Medium** — could break the unattended backup |
| Affected systems | DC01, with knock-on effects on BKP01 and CLIENT01 |
| Downtime | None, but active sessions were affected |

## Reason

`CompanyShare` was created with the Windows default of `Everyone: Full Control`.
That grants complete access to every authenticated principal, which is not
acceptable in any environment where the share is meant to be restricted.

## What changed

**Share permissions**

| Principal | Access |
|---|---|
| `LAB\IT-Team` | Full Control |

`Everyone` removed.

**NTFS permissions**

| Principal | Access | Applies to |
|---|---|---|
| SYSTEM | Full control | This folder, subfolders and files |
| Administrators | Full control | This folder, subfolders and files |
| CREATOR OWNER | Full control | Subfolders and files only |
| `LAB\IT-Team` | Full control | This folder, subfolders and files |

Inheritance from `C:\` was disabled and inherited entries removed, then
permissions were pushed down to existing child objects.

## Why both layers, and why inheritance had to go

Effective access over SMB is the **intersection** of share and NTFS permissions.
Tightening only the share would leave the folder over-permissive to anyone
reaching it locally or through a different share path.

The inheritance step is the one that is easy to miss. The parent volume
propagates `Users: Read & Execute`, and `Domain Users` are members of the local
`Users` group. Leaving inheritance enabled would have silently re-granted read
access to every domain user through NTFS, defeating the share-level restriction
entirely — while the share ACL looked correct.

## Risk assessment

| Risk | Mitigation |
|---|---|
| Unattended backup loses access and fails silently | Backups re-verified immediately after the change; the backup account is a member of `IT-Team` |
| Legitimate users locked out | Verified from CLIENT01 as `lab\ali` before considering the change complete |
| Inherited permissions silently restore access | Inheritance explicitly disabled and inherited entries removed |

## Issue found during verification

Access was tested from CLIENT01 as `lab\ali`. Read succeeded; **write failed**
with *Destination Folder Access Denied*.

`whoami /groups` showed no domain groups in the token. The session was running
on a cached logon issued before `IT-Team` existed. Group membership is written
into the access token at logon and is not refreshed while a session is active.
After signing out and back in, the token contained `LAB\IT-Team` and both read
and write succeeded.

Read had appeared to work during the failure because the SMB session was already
established; only the new write operation triggered a fresh authorisation check.
This is worth recording because the symptom points at permissions being wrong
when the permissions are in fact correct — the token is simply stale.

## Rollback

Re-add `Everyone: Full Control` to the share and re-enable NTFS inheritance.
Not recommended: it restores the condition this change existed to remove.

## Verification

| Check | Expected |
|---|---|
| `Get-SmbShareAccess -Name CompanyShare` | `IT-Team` only, no `Everyone` |
| `Get-Acl C:\CompanyShare` | inheritance disabled, `IT-Team` present |
| Read and write from CLIENT01 as `lab\ali` | both succeed after re-logon |
| `sudo /usr/local/bin/backup-dc01.sh` on BKP01 | completes successfully |

## Outcome

Completed. The daily health check on DC01 now fails if `Everyone` reappears on
the share ACL, so a future reset does not go unnoticed.
