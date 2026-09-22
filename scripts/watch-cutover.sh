#!/usr/bin/env bash
# Sample the authoritative Route 53 answers for a weighted record and count
# how many point at the legacy server vs the ALB.
#   Usage: scripts/watch-cutover.sh <hostname> <zone-id> <legacy-ip> [samples]
set -euo pipefail
HOST="$1"
ZONE_ID="$2"
LEGACY_IP="$3"
SAMPLES="${4:-100}"

NS=$(aws route53 get-hosted-zone --id "${ZONE_ID}" --query 'DelegationSet.NameServers[0]' --output text)
legacy=0
ecs=0
for _ in $(seq 1 "${SAMPLES}"); do
  ip=$(dig +short "${HOST}" A @"${NS}" | head -n1)
  if [ "${ip}" = "${LEGACY_IP}" ]; then legacy=$((legacy + 1)); else ecs=$((ecs + 1)); fi
done
echo "${SAMPLES} answers from ${NS}: legacy=${legacy} ecs=${ecs}"
