#!/usr/bin/env bash
# Check that ECS is serving the expected build for a hostname.
#   Usage: scripts/smoke-test.sh <hostname> <expected-version>
# Uses curl --connect-to so it always talks to the ALB (keeping the real hostname for
# TLS and host-based routing), even while public DNS still points at the legacy server.
set -euo pipefail
HOST="$1"
EXPECTED="$2"
ALB=$(aws elbv2 describe-load-balancers --names expertlisting \
  --query 'LoadBalancers[0].DNSName' --output text)
CURL=(curl -fsS --max-time 10 --connect-to "${HOST}:443:${ALB}:443")

for attempt in $(seq 1 10); do
  api_version=$("${CURL[@]}" "https://${HOST}/api/info" | jq -r .version || true)
  web_version=$("${CURL[@]}" "https://${HOST}/version.txt" || true)
  if [ "${api_version}" = "${EXPECTED}" ] && [ "${web_version}" = "${EXPECTED}" ]; then
    "${CURL[@]}" "https://${HOST}/api/listings" >/dev/null
    echo "Smoke test passed: ${HOST} serves ${EXPECTED}"
    exit 0
  fi
  echo "Attempt ${attempt}: api=${api_version:-none} web=${web_version:-none}, want ${EXPECTED}. Retrying..."
  sleep 6
done
echo "Smoke test FAILED for ${HOST}"
exit 1
