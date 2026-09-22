#!/usr/bin/env bash
# Deploy an already-built image tag to one environment on ECS.
#   Usage: scripts/ecs-deploy.sh <staging|prod> <image-tag>
#
# Terraform owns the *shape* of each task definition (CPU, memory, env, secrets, roles).
# This script owns the *image*: it copies the latest revision, swaps in the new image,
# registers it, runs migrations with it, then rolls the services.
set -euo pipefail

ENV="$1"
TAG="$2"
CLUSTER="expertlisting"
REGION="${AWS_REGION:?AWS_REGION must be set}"
ACCOUNT=$(aws sts get-caller-identity --query Account --output text)
REGISTRY="${ACCOUNT}.dkr.ecr.${REGION}.amazonaws.com"

register_new_revision() {
  local svc="$1"
  local family="expertlisting-${ENV}-${svc}"
  aws ecs describe-task-definition --task-definition "${family}" --query taskDefinition --output json \
    | jq --arg IMAGE "${REGISTRY}/expertlisting/${svc}:${TAG}" '
        .containerDefinitions[0].image = $IMAGE
        | del(.taskDefinitionArn, .revision, .status, .requiresAttributes,
              .compatibilities, .registeredAt, .registeredBy, .deregisteredAt)' \
    > "/tmp/${family}.json"
  aws ecs register-task-definition --cli-input-json "file:///tmp/${family}.json" \
    --query taskDefinition.taskDefinitionArn --output text
}

echo "==> Registering task definitions for ${ENV} @ ${TAG}"
API_TD=$(register_new_revision api)
WEB_TD=$(register_new_revision web)
echo "    api: ${API_TD}"
echo "    web: ${WEB_TD}"

echo "==> Running database migrations with the new image (before any traffic moves)"
NETCFG=$(aws ecs describe-services --cluster "${CLUSTER}" --services "expertlisting-${ENV}-api" \
  --query 'services[0].networkConfiguration' --output json)
TASK_ARN=$(aws ecs run-task --cluster "${CLUSTER}" --launch-type FARGATE \
  --task-definition "${API_TD}" \
  --network-configuration "${NETCFG}" \
  --overrides '{"containerOverrides":[{"name":"api","command":["node","migrate.js"]}]}' \
  --started-by "ci-migrate" \
  --query 'tasks[0].taskArn' --output text)
if [ -z "${TASK_ARN}" ] || [ "${TASK_ARN}" = "None" ]; then
  echo "!! Could not start the migration task"; exit 1
fi
aws ecs wait tasks-stopped --cluster "${CLUSTER}" --tasks "${TASK_ARN}"
EXIT_CODE=$(aws ecs describe-tasks --cluster "${CLUSTER}" --tasks "${TASK_ARN}" \
  --query 'tasks[0].containers[0].exitCode' --output text)
if [ "${EXIT_CODE}" != "0" ]; then
  echo "!! Migrations failed (exit ${EXIT_CODE}). Logs: /ecs/expertlisting-${ENV}-api. Services were NOT changed."
  exit 1
fi
echo "    migrations OK"

echo "==> Rolling services"
aws ecs update-service --cluster "${CLUSTER}" --service "expertlisting-${ENV}-api" --task-definition "${API_TD}" >/dev/null
aws ecs update-service --cluster "${CLUSTER}" --service "expertlisting-${ENV}-web" --task-definition "${WEB_TD}" >/dev/null

echo "==> Waiting for the rolling deployment to settle"
aws ecs wait services-stable --cluster "${CLUSTER}" \
  --services "expertlisting-${ENV}-api" "expertlisting-${ENV}-web"

# If the circuit breaker rolled back, the services are "stable" again but on the OLD
# task definition. Treat that as a failed deploy.
for pair in "api:${API_TD}" "web:${WEB_TD}"; do
  svc="${pair%%:*}"
  want="${pair#*:}"
  have=$(aws ecs describe-services --cluster "${CLUSTER}" --services "expertlisting-${ENV}-${svc}" \
    --query 'services[0].deployments[?status==`PRIMARY`].taskDefinition | [0]' --output text)
  if [ "${have}" != "${want}" ]; then
    echo "!! ${svc}: circuit breaker rolled back. Still running ${have}"
    exit 1
  fi
done
echo "==> ${ENV} is now running ${TAG}"
