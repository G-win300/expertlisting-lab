#!/usr/bin/env bash
# The "old way" Expert Listing deploys today: SSH in, git pull, restart.
# Run ON the legacy server as the ubuntu user:  /opt/expertlisting/legacy/deploy.sh
set -euo pipefail
cd /opt/expertlisting

git pull --ff-only
SHA=$(git rev-parse HEAD)

(cd api && npm ci --omit=dev)
echo "APP_VERSION=${SHA}" | sudo tee /etc/expertlisting-version.env >/dev/null

# One-shot unit: blocks until migrations finish and fails this script if they fail.
sudo systemctl start expertlisting-migrate

rm -rf /var/www/expertlisting/*
cp -r web/public/. /var/www/expertlisting/
echo "${SHA}" > /var/www/expertlisting/version.txt

# This restart is the downtime window: in-flight requests are dropped.
sudo systemctl restart expertlisting-api
echo "Deployed ${SHA}"
