# Design decisions

Short, ADR-style records of the choices behind this change. Each one states
the context, the decision, and what was given up.

---

## ADR-001: Swap as a safety net, not a capacity fix

**Context.** Application nodes ran at roughly 75–80% memory use with no swap.
A spike or leak would invoke the OOM killer, which targets the largest
process: the application.

**Decision.** Add swap sized to absorb a spike (8 GiB, about 25% of RAM on the
nodes in scope) and tune the kernel to avoid using it in normal operation.

**Consequences.** Spikes degrade latency instead of killing the process.
Swap does **not** add usable capacity: sustained paging is a signal to
right-size, and monitoring is set up to surface it
([monitoring](../monitoring/README.md)).

---

## ADR-002: Swap file rather than a swap partition or a new EBS volume

### Options considered

| Option | Pros | Cons |
| --- | --- | --- |
| Swap **file** on root volume | No new resources, no repartitioning, online, easy to resize or remove | Shares root volume IOPS |
| Swap **partition** | Marginally simpler kernel path | Requires repartitioning; not possible online on a full-size root |
| Dedicated **EBS volume** | Isolates IOPS, independently sized | New resource to attach, tag, encrypt, monitor and pay for; extra failure mode |
| **Instance store** | Fastest | Only on some instance types; ephemeral; must be recreated on every stop/start |

**Decision.** Swap file on the root volume. On modern kernels swap files
perform on par with partitions, and with low swappiness the IOPS contention is
negligible.

---

## ADR-003: `dd` rather than `fallocate`

`fallocate` is near-instant, but on XFS it creates *unwritten extents*, and
`swapon` can reject such files ("swapfile has holes") depending on kernel
version. `dd` writes real zeroes and works on every supported filesystem.

**Trade-off.** About 65 s of write time per node instead of under 1 s.
Acceptable for a one-off change.

---

## ADR-004: `oflag=direct` on the `dd` write

**Context.** Hosts had only about 20% memory available. A buffered 8 GiB
write goes through the page cache, which would evict the application's
cached files and could briefly push the host into the memory pressure this
change is meant to prevent.

**Decision.** Write with `O_DIRECT` (`oflag=direct`), bypassing the page
cache.

**Consequence.** No cache churn was observed during the write. Throughput
was limited by the volume (about 133 MB/s on gp3 baseline), not the cache.

---

## ADR-005: `vm.swappiness = 10`

`vm.swappiness` sets how willing the kernel is to reclaim memory by swapping
out anonymous (application) pages rather than dropping file cache. It is a
relative weighting, **not** a "start swapping at N% full" threshold.

| Value | Behaviour | Fit |
| --- | --- | --- |
| 60 (default) | Swaps app memory fairly readily | Desktops |
| **10** | Strongly prefers dropping file cache; swaps only under real pressure | **App servers** |
| 0 | Avoids swap almost entirely until near OOM | Latency-critical, or no real safety margin |
| 1 | Minimum without fully avoiding swap | Databases with large buffer pools |

**Decision.** 10. The application's working set stays in RAM, and swap still
engages before the OOM killer would.

---

## ADR-006: 8 GiB size

Classic rules ("2× RAM") predate large-memory servers and hibernation does not
apply to EC2. Sizing was instead based on:

- Headroom needed for the largest observed spike, plus a margin
- Keeping total "time to OOM" bounded: a very large swap lets a leaking
  process thrash for hours instead of failing fast and being restarted
- Root volume free space (at least 50 GiB free on every node)

8 GiB (about 25% of RAM) covers spikes without masking leaks.

---

## ADR-007: Rolling, one node at a time, through SSM

### Options considered

| Option | Why not chosen |
| --- | --- |
| All nodes at once | A defect would hit the whole tier simultaneously |
| SSM `send-command` with `--max-concurrency 1` against a tag | Rolls, but cannot gate on ALB health or soak between hosts |
| Ansible over SSH | Needs SSH access, keys and a bastion; not otherwise used in this estate |
| **Scripted loop over SSM, per-host gates** | **Chosen** |

**Decision.** `rolling-rollout.sh` loops over hosts and, for each, runs
preflight → configure → verify via `AWS-RunShellScript`, waits for target
group health, then soaks. Any failure stops the run.

Scripts are shipped inline (base64) so the code executed is exactly the
reviewed code in the repository, with no artefact bucket to secure or keep
in sync.

---

## ADR-008: Idempotency and self-healing fstab edits

Every step in `configure-swap.sh` checks state first, so a re-run after a
partial failure completes the job instead of erroring or duplicating
entries. The fstab edit is backed up, validated with `mount -a` and
`swapon -a`, and auto-restored if validation fails, because a malformed
fstab is one of the few ways this change could stop a host from booting.

---

## ADR-009: No reboot to "prove" persistence

A test reboot would confirm the fstab and sysctl entries, but on production
it trades a small, unlikely risk (a misread fstab) for a certain one (a node
out of service). The fstab is validated in place instead, and persistence is
confirmed opportunistically at the next planned reboot.

---

## ADR-010: Memory-safe rollback

`swapoff` must page every swapped-out page back into RAM. If swap is in use
and RAM is short, `swapoff` itself can trigger the OOM killer. The rollback
script therefore refuses to run unless `MemAvailable` exceeds swap in use
plus a 1 GiB margin, and requires an explicit `--force` to override.
