# Rollback

## When to roll back

Roll back a node if, after the change:

- the application's error rate or latency degrades and does not recover
  within the soak window, **and** the timing points at this change
- `vmstat 5` shows sustained `si`/`so` (heavy paging) that hurts latency
- verification fails and a re-run of `configure-swap.sh` does not fix it

Swap that is merely *allocated* (`swap_used` > 0 but no ongoing `si`/`so`) is
**not** a reason to roll back. Those pages were idle and are now out of the
way.

## Automated

```bash
# All nodes, one at a time
make rollback TAG=Role=app REGION=eu-west-1

# Single node
./scripts/rolling-rollout.sh --instances i-0aaaaaaaaaaaaaaaa --action rollback
```

On the host directly:

```bash
sudo ./scripts/rollback-swap.sh
```

What it does, in order:

1. Checks that `MemAvailable` exceeds the swap currently in use plus 1 GiB.
   If not, it **refuses** (see below).
2. `swapoff /swapfile`
3. Removes the fstab entry (backup first; validated with `mount -a`)
4. Deletes `/swapfile`
5. Removes `/etc/sysctl.d/99-swap.conf` and restores the default swappiness

### "not enough free RAM to absorb swapped pages safely"

`swapoff` has to load every swapped page back into RAM. If RAM cannot hold
them, `swapoff` itself can trigger the OOM killer, which is exactly the
outcome swap was added to prevent.

Options, in order of preference:

1. Wait for a quieter period, when `MemAvailable` is higher.
2. Drain the node from the load balancer, restart the application to release
   memory, then roll back.
3. `sudo ./scripts/rollback-swap.sh --force`, accepting the OOM risk.

## Manual

```bash
free -h                                   # check swap 'used' vs 'available' RAM first
sudo swapoff /swapfile
sudo cp /etc/fstab /etc/fstab.bak.$(date +%F)-rollback
sudo sed -i '\|^/swapfile[[:space:]]|d' /etc/fstab
sudo mount -a && echo "fstab OK"
sudo rm /swapfile
sudo rm -f /etc/sysctl.d/99-swap.conf
sudo sysctl -w vm.swappiness=60
free -h                                   # Swap: 0B
```

## Last resort: restore from snapshot

If a node will not boot after a reboot (for example a corrupted fstab), use
the pre-change snapshot:

1. Stop the instance.
2. Create a volume from the `<node>-pre-swap-<date>` snapshot in the same AZ.
3. Detach the current root volume and attach the restored one as the root
   device (same device name).
4. Start the instance and confirm it is healthy.

Alternatively, attach the broken root volume to a rescue instance, fix
`/etc/fstab`, and reattach it. That keeps any data written since the
snapshot.
