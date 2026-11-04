# Changelog

All notable changes to this project are documented here.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and the project uses [Semantic Versioning](https://semver.org/spec/v2.0.0.html).
Commit messages follow [Conventional Commits](https://www.conventionalcommits.org/en/v1.0.0/).

## [Unreleased]

### Planned

- Terraform module to register the SSM document and add swap setup to
  launch template user data for Auto Scaling Groups

## [1.0.0] - 2026-11-04

### Added

- `scripts/preflight.sh`: read-only checks for existing swap, filesystem
  type, free disk and fstab state; non-zero exit gates the rollout.
- `scripts/configure-swap.sh`: idempotent swap setup:
  - `dd oflag=direct` to avoid page cache churn on memory-constrained hosts
  - file created under `umask 077` (never world-readable)
  - fstab backup, validation (`mount -a`, `swapon -a`) and automatic restore
  - persisted `vm.swappiness` via `/etc/sysctl.d/99-swap.conf`
- `scripts/verify-swap.sh`: post-change assertions for size, permissions,
  a single fstab entry and swappiness (live and persisted).
- `scripts/rollback-swap.sh`: removal with a memory-safety check before
  `swapoff`, plus `--force` override.
- `scripts/rolling-rollout.sh`: one-at-a-time fleet rollout over SSM Run
  Command with fail-fast gates, optional target group health wait, soak
  period, dry-run mode and per-run log files.
- `ssm/configure-swap.yml`: SSM Command document generated from
  `configure-swap.sh` by `scripts/build-ssm-document.sh`, with a drift check.
- `monitoring/`: CloudWatch agent config for memory, swap and disk metrics,
  with suggested alarms.
- Documentation: runbook, design decisions (ADRs), rollback guide and
  sanitized change record.
- CI: ShellCheck, yamllint, markdownlint, SSM document drift check, mock-AWS
  orchestration tests and an end-to-end run of the host scripts.
- `Makefile` targets: `lint`, `test`, `ssm-doc`, `preflight`, `rollout`,
  `verify`, `rollback`.

[Unreleased]: https://github.com/adijain-99/ec2-rolling-swap-rollout/compare/v1.0.0...HEAD
[1.0.0]: https://github.com/adijain-99/ec2-rolling-swap-rollout/releases/tag/v1.0.0
