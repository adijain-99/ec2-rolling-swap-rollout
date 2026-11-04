#!/usr/bin/env bash
#
# rolling-rollout.sh — apply swap configuration to a fleet of EC2 instances,
# one instance at a time, through AWS Systems Manager Run Command.
#
# Per instance:
#   1. Confirm the instance is SSM-managed and Online
#   2. Run preflight.sh          (stop the rollout on any failure)
#   3. Run configure-swap.sh     (stop the rollout on any failure)
#   4. Run verify-swap.sh        (stop the rollout on any failure)
#   5. Optionally wait for the instance to be healthy in its target group
#   6. Soak for --soak-seconds before moving to the next instance
#
# No SSH, no bastion: scripts are shipped inline (base64) through the
# AWS-RunShellScript document, so what runs is exactly what is in this repo.
#
# Usage:
#   rolling-rollout.sh (--instances ID[,ID...] | --tag KEY=VALUE) [options]
#
# Options:
#   --instances IDS          Comma-separated instance IDs, processed in order
#   --tag KEY=VALUE          Select running instances by tag (sorted by Name tag)
#   --region REGION          AWS region (default: from AWS CLI config)
#   --action ACTION          configure | verify | rollback   (default: configure)
#   --swap-size-mib N        Swap file size in MiB           (default: 8192)
#   --swappiness N           vm.swappiness value             (default: 10)
#   --target-group-arn ARN   Wait for 'healthy' in this target group after each host
#   --soak-seconds N         Wait between instances          (default: 600)
#   --dry-run                Run preflight only, change nothing
#   --yes                    Do not prompt for confirmation
#   -h, --help               Show this help
#
# Requirements: aws CLI v2, jq. IAM: ssm:SendCommand, ssm:GetCommandInvocation,
# ssm:DescribeInstanceInformation, ec2:DescribeInstances and, if
# --target-group-arn is used, elasticloadbalancing:DescribeTargetHealth.

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"

INSTANCES=""
TAG=""
REGION=""
ACTION="configure"
SWAP_SIZE_MIB=8192
SWAPPINESS=10
TARGET_GROUP_ARN=""
SOAK_SECONDS=600
DRY_RUN=0
ASSUME_YES=0
COMMAND_TIMEOUT=1800      # seconds allowed for one remote script
HEALTH_TIMEOUT=600        # seconds to wait for target group health

RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)"
LOG_DIR="${REPO_ROOT}/logs"
LOG_FILE="${LOG_DIR}/rollout-${RUN_ID}.log"

log()  { printf '%s [rollout] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" | tee -a "$LOG_FILE" >&2; }
die()  { log "ERROR $*"; exit 1; }

usage() { sed -n '3,36p' "$0" | sed 's/^# \{0,1\}//'; }

# --- Argument parsing --------------------------------------------------------
while (( $# > 0 )); do
  case "$1" in
    --instances)        INSTANCES="$2"; shift 2 ;;
    --tag)              TAG="$2"; shift 2 ;;
    --region)           REGION="$2"; shift 2 ;;
    --action)           ACTION="$2"; shift 2 ;;
    --swap-size-mib)    SWAP_SIZE_MIB="$2"; shift 2 ;;
    --swappiness)       SWAPPINESS="$2"; shift 2 ;;
    --target-group-arn) TARGET_GROUP_ARN="$2"; shift 2 ;;
    --soak-seconds)     SOAK_SECONDS="$2"; shift 2 ;;
    --dry-run)          DRY_RUN=1; shift ;;
    --yes)              ASSUME_YES=1; shift ;;
    -h|--help)          usage; exit 0 ;;
    *)                  usage; echo "Unknown option: $1" >&2; exit 2 ;;
  esac
done

mkdir -p "$LOG_DIR"

command -v aws >/dev/null || die "aws CLI not found"
command -v jq  >/dev/null || die "jq not found"

[[ -n "$INSTANCES" || -n "$TAG" ]] || { usage; die "one of --instances or --tag is required"; }
[[ -z "$INSTANCES" || -z "$TAG" ]] || die "use --instances or --tag, not both"
case "$ACTION" in configure|verify|rollback) ;; *) die "invalid --action: ${ACTION}" ;; esac
for n in "$SWAP_SIZE_MIB" "$SWAPPINESS" "$SOAK_SECONDS"; do
  [[ "$n" =~ ^[0-9]+$ ]] || die "numeric option expected, got '${n}'"
done

AWS=(aws)
[[ -n "$REGION" ]] && AWS+=(--region "$REGION")

# --- Resolve targets -----------------------------------------------------------
resolve_instances() {
  if [[ -n "$INSTANCES" ]]; then
    tr ',' '\n' <<<"$INSTANCES" | sed '/^$/d'
    return
  fi
  local key="${TAG%%=*}" value="${TAG#*=}"
  [[ "$key" != "$TAG" ]] || die "--tag must be KEY=VALUE"
  "${AWS[@]}" ec2 describe-instances \
    --filters "Name=tag:${key},Values=${value}" "Name=instance-state-name,Values=running" \
    --output json \
  | jq -r '[.Reservations[].Instances[]
             | {id: .InstanceId, name: ((.Tags // []) | map(select(.Key=="Name")) | .[0].Value // "")}]
           | sort_by(.name) | .[].id'
}

mapfile -t TARGETS < <(resolve_instances)
(( ${#TARGETS[@]} > 0 )) || die "no instances matched"

# --- Remote execution helpers --------------------------------------------------
# Runs a local script on one instance via SSM and streams its output.
# Returns the remote script's exit status (non-zero on any failure).
run_remote() {
  local instance="$1" script="$2" extra_args="${3:-}"
  local b64 cmd params command_id status

  b64="$(base64 -w0 "$script")"
  cmd="f=\$(mktemp) && echo '${b64}' | base64 -d > \"\$f\" && \
SWAP_SIZE_MIB=${SWAP_SIZE_MIB} SWAPPINESS=${SWAPPINESS} bash \"\$f\" ${extra_args}; \
rc=\$?; rm -f \"\$f\"; exit \$rc"
  params="$(jq -cn --arg c "$cmd" --arg t "$COMMAND_TIMEOUT" \
    '{commands: [$c], executionTimeout: [$t]}')"

  command_id="$("${AWS[@]}" ssm send-command \
    --instance-ids "$instance" \
    --document-name "AWS-RunShellScript" \
    --comment "swap-rollout ${RUN_ID} $(basename "$script")" \
    --parameters "$params" \
    --query 'Command.CommandId' --output text)"
  log "${instance}: $(basename "$script") -> command ${command_id}"

  local waited=0
  while :; do
    sleep "${POLL_SECONDS:-5}"; waited=$((waited + 5))
    status="$("${AWS[@]}" ssm get-command-invocation \
      --command-id "$command_id" --instance-id "$instance" \
      --query 'Status' --output text 2>/dev/null || echo Pending)"
    case "$status" in
      Pending|InProgress|Delayed) ;;
      *) break ;;
    esac
    (( waited < COMMAND_TIMEOUT + 60 )) || { status="TimedOut(local)"; break; }
  done

  "${AWS[@]}" ssm get-command-invocation \
    --command-id "$command_id" --instance-id "$instance" --output json 2>/dev/null \
  | jq -r '.StandardOutputContent, (.StandardErrorContent | select(length > 0) | "STDERR:\n" + .)' \
  | sed "s/^/    [${instance}] /" | tee -a "$LOG_FILE" >&2

  log "${instance}: $(basename "$script") finished with status ${status}"
  [[ "$status" == "Success" ]]
}

check_ssm_online() {
  local instance="$1" ping
  ping="$("${AWS[@]}" ssm describe-instance-information \
    --filters "Key=InstanceIds,Values=${instance}" \
    --query 'InstanceInformationList[0].PingStatus' --output text 2>/dev/null || true)"
  [[ "$ping" == "Online" ]] || die "${instance}: not SSM-managed or not Online (PingStatus=${ping:-none})"
  log "${instance}: SSM agent Online"
}

wait_target_healthy() {
  local instance="$1" state waited=0
  [[ -n "$TARGET_GROUP_ARN" ]] || return 0
  while :; do
    state="$("${AWS[@]}" elbv2 describe-target-health \
      --target-group-arn "$TARGET_GROUP_ARN" \
      --query "TargetHealthDescriptions[?Target.Id=='${instance}'].TargetHealth.State | [0]" \
      --output text 2>/dev/null || echo unknown)"
    if [[ "$state" == "healthy" ]]; then
      log "${instance}: target group state healthy"; return 0
    fi
    if [[ "$state" == "None" || "$state" == "unused" ]]; then
      log "${instance}: WARN not registered in target group (state=${state}); continuing"; return 0
    fi
    (( waited < HEALTH_TIMEOUT )) || die "${instance}: not healthy after ${HEALTH_TIMEOUT}s (state=${state})"
    sleep 15; waited=$((waited + 15))
  done
}

# --- Plan + confirmation ----------------------------------------------------------
log "Run ${RUN_ID}: action=${ACTION} dry_run=${DRY_RUN} size=${SWAP_SIZE_MIB}MiB swappiness=${SWAPPINESS} soak=${SOAK_SECONDS}s"
log "Targets (in order): ${TARGETS[*]}"
log "Log file: ${LOG_FILE}"

if (( ASSUME_YES == 0 )); then
  read -r -p "Proceed with ${ACTION} on ${#TARGETS[@]} instance(s)? Type 'yes' to continue: " answer
  [[ "$answer" == "yes" ]] || die "aborted by operator"
fi

# --- Rollout loop -------------------------------------------------------------------
total=${#TARGETS[@]}
for i in "${!TARGETS[@]}"; do
  instance="${TARGETS[$i]}"
  log "===== [$((i + 1))/${total}] ${instance} ====="
  check_ssm_online "$instance"

  case "$ACTION" in
    configure)
      run_remote "$instance" "${SCRIPT_DIR}/preflight.sh" \
        || die "${instance}: preflight failed — rollout stopped, no changes made to this host"
      if (( DRY_RUN == 1 )); then
        log "${instance}: dry run — skipping configure"
        continue
      fi
      run_remote "$instance" "${SCRIPT_DIR}/configure-swap.sh" \
        || die "${instance}: configure failed — rollout stopped. See docs/rollback.md"
      run_remote "$instance" "${SCRIPT_DIR}/verify-swap.sh" \
        || die "${instance}: verification failed — rollout stopped. See docs/rollback.md"
      ;;
    verify)
      run_remote "$instance" "${SCRIPT_DIR}/verify-swap.sh" \
        || die "${instance}: verification failed"
      continue
      ;;
    rollback)
      (( DRY_RUN == 0 )) || { log "${instance}: dry run — skipping rollback"; continue; }
      run_remote "$instance" "${SCRIPT_DIR}/rollback-swap.sh" \
        || die "${instance}: rollback failed — rollout stopped"
      ;;
  esac

  wait_target_healthy "$instance"

  if (( i + 1 < total && SOAK_SECONDS > 0 )); then
    log "${instance}: done. Soaking ${SOAK_SECONDS}s before next instance (Ctrl-C to stop safely)"
    sleep "$SOAK_SECONDS"
  fi
done

log "Rollout ${RUN_ID} complete: ${ACTION} applied to ${total} instance(s)"
