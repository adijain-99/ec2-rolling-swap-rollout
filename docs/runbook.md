# Runbook: add swap to application servers (manual, rolling)

Use this runbook when carrying out the change by hand, for example over SSM
Session Manager, or to understand exactly what `rolling-rollout.sh`
automates. The automated and manual paths make identical changes.

| | |
| --- | --- |
| **Scope** | Application tier: `app-node-01`, `app-node-02`, `app-node-03` |
| **Change** | Add 8 GiB swap file, set `vm.swappiness=10` |
| **Downtime** | None expected. No reboot, no service restart |
| **Duration** | About 5 min per node + 10–15 min soak, about 45 min total |
| **Rollback** | [`rollback.md`](rollback.md), about 2 min per node |

Do **one node at a time**. Do not start the next node until the current one
has passed Step 7 and the soak period.

---

## Step 0: Before you start (once per change)

1. **Change record approved.** See [`change-record.md`](change-record.md).
2. **Auto Scaling Group check.** In the EC2 console, open the instance and
   look for the tag `aws:autoscaling:groupName`. If present, also update the
   launch template or AMI, or replacements will not get swap.
3. **Load balancer check.** Note the target group(s) the nodes belong to.
4. **Monitoring open.** Have the target group health, the application
   dashboard and error logs open for the duration.

## Step 1: Snapshot the root volume

EC2 → Instances → *node* → **Storage** → root volume ID →
**Actions → Create snapshot**.

Name it `<node>-pre-swap-<YYYY-MM-DD>`.

✅ Snapshot status is `Pending` or `Completed`. You do not need to wait for
completion: EBS snapshots are crash-consistent from the moment they start.

## Step 2: Pre-flight checks (read-only)

Connect with SSM Session Manager, then:

```bash
free -h
swapon --show
df -hT /
lsblk
head -3 /etc/os-release
```

Example output:

```text
               total        used        free      shared  buff/cache   available
Mem:            31Gi        23Gi       702Mi       6.0Mi       6.9Gi       7.4Gi
Swap:             0B          0B          0B
Filesystem     Type  Size  Used Avail Use% Mounted on
/dev/nvme0n1p1 xfs   150G   58G   93G  39% /
```

✅ **Continue if:**

- `Swap:` is `0B` and `swapon --show` prints nothing
- `Avail` on `/` is at least **10G** (8 GiB swap + 2 GiB headroom)
- Filesystem type is `xfs` or `ext4`

⛔ **Stop if:** swap already exists, disk is short (grow the EBS volume first:
console *Modify volume*, then `growpart` and `xfs_growfs -d /`), or the
filesystem is anything else.

## Step 3: (Optional) Drain from the load balancer

Writing 8 GiB uses EBS throughput for about a minute. With `oflag=direct` this
has not been observed to affect latency on gp3, so draining is optional. For
the most cautious path:

EC2 → Target Groups → *group* → **Targets** → select node → **Deregister**.
Wait until the node leaves the `draining` state.

> If you drain here, you **must** re-register in Step 7.

## Step 4: Create the swap file

```bash
sudo dd if=/dev/zero of=/swapfile bs=1M count=8192 oflag=direct status=progress
ls -lh /swapfile
```

Expected:

```text
8589934592 bytes (8.6 GB, 8.0 GiB) copied, 64.7 s, 133 MB/s
-rw-r--r--. 1 root root 8.0G <date> /swapfile
```

About 65 s at gp3 baseline throughput (125 MB/s).

- `oflag=direct` keeps the 8 GiB write out of the page cache, so the
  application's cached data is not evicted on a host already short of memory.
- `dd` rather than `fallocate`: `swapon` can reject preallocated files on XFS.

## Step 5: Secure, format and enable

```bash
sudo chmod 600 /swapfile
ls -lh /swapfile
sudo mkswap /swapfile
sudo swapon /swapfile
swapon --show
free -h
```

Expected:

```text
-rw-------. 1 root root 8.0G <date> /swapfile
Setting up swapspace version 1, size = 8 GiB (8589930496 bytes)
NAME      TYPE SIZE USED PRIO
/swapfile file   8G   0B   -2
Swap:          8.0Gi          0B       8.0Gi
```

✅ Permissions are `-rw-------` and `Swap:` shows `8.0Gi`.

> The automated script creates the file under `umask 077`, so it is never
> world-readable, not even for the minute before `chmod`.

## Step 6: Persist across reboots

### 6a. fstab

```bash
sudo cp /etc/fstab /etc/fstab.bak.$(date +%F)
echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab
cat /etc/fstab
sudo mount -a && echo "fstab OK"
sudo swapon -a && echo "swapon OK"
```

✅ The `/swapfile` line appears **once**, at the end, and both `OK` lines
print. (The first `/swapfile ...` line of output is `tee` echoing what it
wrote.)

⛔ On any error: **do not reboot.** Restore and investigate:

```bash
sudo cp /etc/fstab.bak.$(date +%F) /etc/fstab
```

### 6b. Swappiness

```bash
cat /proc/sys/vm/swappiness
echo 'vm.swappiness=10' | sudo tee /etc/sysctl.d/99-swap.conf
sudo sysctl -p /etc/sysctl.d/99-swap.conf
cat /proc/sys/vm/swappiness
```

✅ Goes from `60` to `10`.

## Step 7: Verify

```bash
swapon --show
free -h
cat /proc/sys/vm/swappiness
grep swap /etc/fstab
df -h /
```

Or, from a checkout of this repository on the host:

```bash
sudo ./scripts/verify-swap.sh
```

✅ All of:

- `/swapfile file 8G` is active and `Swap: 8.0Gi`
- swappiness is `10`
- exactly one fstab line
- disk use is up by 8 GiB and nothing else changed
- the node is `healthy` in its target group (re-register it now if you
  drained it in Step 3)
- application health checks, error rate and latency are normal

Swap usage showing `0B` straight after the change is expected. With
swappiness 10 the kernel only uses swap under real memory pressure.

## Step 8: Soak, then the next node

Wait **10–15 minutes**, watching the dashboards. If everything is still
normal, repeat Steps 1–8 on the next node.

---

## After the last node

- [ ] All nodes pass Step 7
- [ ] Change record updated with completion time and outcome
- [ ] Snapshots kept for 7 days, then deleted
- [ ] CloudWatch agent memory/swap metrics and alarms in place (see
      [`../monitoring/README.md`](../monitoring/README.md))
- [ ] Launch template / AMI updated if any node is ASG-managed

## FAQ

**Do I need to reboot or restart the application?**
No. `swapon` and `sysctl -p` take effect immediately, and the kernel manages
swap transparently to processes. The fstab and sysctl.d entries cover future
reboots. A test reboot on production is unnecessary risk; confirm with
`free -h` after the next planned reboot instead.

**Where do the 8 GiB come from?**
Free space on the root EBS volume. RAM is unchanged; the memory available
before the OOM killer acts grows from RAM to RAM + 8 GiB.

**Does this cost anything?**
Nothing extra. It uses space on a volume that is already provisioned.
