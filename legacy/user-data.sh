#!/bin/bash
# EC2 user-data for the simulated "legacy" server (Ubuntu 24.04).
set -euxo pipefail
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y nginx nodejs npm git certbot python3-certbot-nginx jq postgresql-client
mkdir -p /opt/expertlisting /var/www/expertlisting
chown ubuntu:ubuntu /opt/expertlisting /var/www/expertlisting
