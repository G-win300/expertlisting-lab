#!/usr/bin/env bash
# One-time setup of the legacy server. Run ON the server, after cloning the repo:
#   sudo /opt/expertlisting/legacy/setup.sh app.lab.yourdomain.com you@example.com
set -euo pipefail
HOST="$1"
EMAIL="$2"
REPO_DIR=/opt/expertlisting

sed "s/__SERVER_NAME__/${HOST}/" "${REPO_DIR}/legacy/nginx-legacy.conf" > /etc/nginx/sites-available/expertlisting
ln -sf /etc/nginx/sites-available/expertlisting /etc/nginx/sites-enabled/expertlisting
rm -f /etc/nginx/sites-enabled/default
nginx -t
systemctl reload nginx

cp "${REPO_DIR}/legacy/expertlisting-api.service" "${REPO_DIR}/legacy/expertlisting-migrate.service" /etc/systemd/system/
touch /etc/expertlisting-version.env
systemctl daemon-reload
systemctl enable expertlisting-api

# First deploy, the same way every later deploy happens.
sudo -u ubuntu "${REPO_DIR}/legacy/deploy.sh"

# TLS from Let's Encrypt. Needs DNS for $HOST pointing at this server.
certbot --nginx -d "${HOST}" --non-interactive --agree-tos -m "${EMAIL}" --redirect
echo "Legacy server ready at https://${HOST}"
