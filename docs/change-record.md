# Change record: add swap to application tier

> Sanitized example of the change request raised for this work. Identifiers,
> names and dates are placeholders.

| Field | Value |
| --- | --- |
| **Change ID** | CHG-XXXX |
| **Type** | Normal (pre-approved pattern after first execution) |
| **Environment** | Production |
| **Service** | Customer-facing web application, app tier |
| **Requested by** | Platform / DevOps |
| **Implementer** | DevOps engineer |
| **Window** | Off-peak, weekday evening |
| **Expected duration** | 45 minutes (3 nodes × ~5 min + soak) |

## Summary

Add an 8 GiB swap file and set `vm.swappiness=10` on the three application
servers, one at a time, with no downtime.

## Justification

The nodes run at about 75–80% memory use with **no swap**. A memory spike
would invoke the OOM killer against the application process and drop live
requests. Swap gives a buffer that degrades gracefully instead.

## Scope

| In scope | Out of scope |
| --- | --- |
| `app-node-01`, `app-node-02`, `app-node-03` | All other server tiers |
| Root volume swap file, kernel parameter | Instance type changes, application config |

## Risk assessment

| Risk | Likelihood | Impact | Mitigation |
| --- | --- | --- | --- |
| I/O during swap file creation slows the app | Low | Low | `oflag=direct`; ~65 s per node; one node at a time |
| Malformed fstab prevents boot | Very low | High | Backup + `mount -a`/`swapon -a` validation; snapshot |
| Root volume fills | Very low | High | Pre-flight requires size + 2 GiB free |
| Swap used heavily, latency rises | Low | Medium | swappiness 10; monitoring; rollback available |

**Overall risk:** Low. **Customer impact:** None expected.

## Pre-checks

- [ ] EBS snapshot of each root volume
- [ ] Each node: no existing swap, ≥ 10 GiB free on `/`, xfs/ext4
- [ ] Nodes not in an Auto Scaling Group (or launch template updated)
- [ ] Dashboards and target group health open

## Implementation plan

Per node, in order 01 → 02 → 03:

1. Pre-flight checks
2. Create swap file (`dd`, `oflag=direct`)
3. `chmod 600`, `mkswap`, `swapon`
4. Persist in `/etc/fstab` and validate
5. Set and persist `vm.swappiness=10`
6. Verify, confirm target health
7. Soak 10–15 minutes

Detailed steps: [`runbook.md`](runbook.md).

## Verification

- `swapon --show` lists `/swapfile` at 8G
- `vm.swappiness` = 10, persisted
- Exactly one fstab entry
- Target group shows the node healthy; error rate and latency at baseline

## Back-out plan

[`rollback.md`](rollback.md): `swapoff`, remove the fstab entry, delete the
file, remove the sysctl drop-in. About 2 minutes per node, no restart.
Snapshot restore is the last resort.

## Outcome

| Node | Start | End | Result |
| --- | --- | --- | --- |
| app-node-01 | T+0 | T+8 min | ✅ Verified, no impact |
| app-node-02 | T+40 min | T+46 min | ✅ Verified, no impact |
| app-node-03 | T+100 min | T+104 min | ✅ Verified, no impact |

No errors, no alerts and no latency change during or after the change.
Snapshots retained for 7 days.

## Follow-ups

- Roll out the CloudWatch agent with memory/swap metrics and alarms
- Review memory headroom: if swap is used regularly, right-size the instances
- Automate future runs with `rolling-rollout.sh`
