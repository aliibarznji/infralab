# INC-NNN — <short factual title>

| Field | Value |
|---|---|
| Date | YYYY-MM-DD |
| Detected at | HH:MM |
| Resolved at | HH:MM |
| Duration | Nm |
| Severity | Critical / Major / Minor |
| Affected systems | |
| Detected by | Alert name, or "manual observation" |
| Simulated | Yes — deliberate exercise |

## Summary

Two or three sentences: what broke, what the visible effect was, how it was
resolved.

## Detection

Which alert fired, at what time, and how long after the fault was introduced.

**If monitoring did not catch it, say so plainly.** That is the most valuable
finding an exercise like this can produce, and burying it wastes the exercise.

## Timeline

| Time | Event |
|---|---|
| HH:MM | Fault introduced |
| HH:MM | Alert entered pending |
| HH:MM | Alert fired, delivered to alert-sink |
| HH:MM | Investigation began |
| HH:MM | Root cause identified |
| HH:MM | Fix applied |
| HH:MM | Alert resolved |

Delivery times come from `/var/log/alert-sink/alert-sink.log` on MON01.

## Investigation

What was checked, in order, and what each step ruled in or out. Include the real
commands and their real output.

**Dead ends belong here.** They are the part that shows how you actually reason
about a fault, and removing them makes the writeup look like a script rather
than an investigation.

## Root cause

The specific cause. Not "the disk filled" but what filled it and why nothing
stopped it earlier.

## Resolution

What was done, and how it was verified as fixed rather than assumed fixed.

## Prevention

What would stop a recurrence or catch it sooner. Be explicit about what was
actually implemented versus what was only identified.

## What this exercise revealed

Anything that behaved differently from expectation: an alert that fired later
than intended, a threshold that was wrong, a runbook step that did not work, a
dependency nobody had written down.
