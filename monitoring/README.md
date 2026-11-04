# Monitoring swap

EC2 does not report memory or swap to CloudWatch out of the box. Those
metrics come from inside the guest OS, so they need the CloudWatch agent.

## 1. Install and start the agent

On Amazon Linux 2023:

```bash
sudo dnf install -y amazon-cloudwatch-agent
sudo cp monitoring/cloudwatch-agent.json /opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.json
sudo /opt/aws/amazon-cloudwatch-agent/bin/amazon-cloudwatch-agent-ctl \
  -a fetch-config -m ec2 -s \
  -c file:/opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.json
```

Across a fleet, push the same config through SSM: store it in Parameter Store
and run the `AmazonCloudWatch-ManageAgent` document against the instances.

The instance role needs the AWS managed policy `CloudWatchAgentServerPolicy`.

## 2. Metrics collected

| Metric | Why it matters |
| --- | --- |
| `mem_used_percent` | Baseline memory pressure |
| `mem_available_percent` | What the kernel can still hand out without swapping |
| `swap_used_percent` | Primary signal that swap is actually being relied on |
| `swap_used` / `swap_free` | Absolute values for capacity planning |
| `disk used_percent` (`/`) | The swap file lives on the root volume |

## 3. Suggested alarms

| Alarm | Condition | Meaning |
| --- | --- | --- |
| Swap in sustained use | `swap_used_percent > 25` for 15 min | Host is short of RAM; investigate or right-size |
| Swap nearly full | `swap_used_percent > 80` for 5 min | OOM kills are close |
| Memory pressure | `mem_available_percent < 10` for 10 min | Early warning before swapping starts |

Example (one instance; replace the placeholders):

```bash
aws cloudwatch put-metric-alarm \
  --alarm-name "app-node-01-swap-sustained" \
  --namespace CWAgent \
  --metric-name swap_used_percent \
  --dimensions Name=InstanceId,Value=<instance-id> \
  --statistic Average --period 300 --evaluation-periods 3 \
  --threshold 25 --comparison-operator GreaterThanThreshold \
  --treat-missing-data notBreaching \
  --alarm-actions <sns-topic-arn>
```

## 4. Reading swap activity on the host

Usage alone can mislead: pages that were swapped out once and never touched
again cost nothing. What hurts is **active paging**.

```bash
vmstat 5
```

Watch the `si` (swap-in) and `so` (swap-out) columns. Occasional non-zero
values are normal. Sustained non-zero `si` means the application is waiting
on disk for its own memory, and latency will show it. That is the signal to
add RAM, not more swap.
