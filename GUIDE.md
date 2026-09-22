# Part A, hands-on: from "SSH and git pull" to ECS on Fargate

This lab builds the Expert Listing Part A design end to end, on your own AWS account and domain. You start by recreating the platform as the brief describes it today: one server deployed over SSH, plus a managed Postgres database. Then you migrate it, step by step and without downtime, to containers on ECS Fargate with Terraform and a GitHub Actions pipeline.

By the end you will have done every step in your written answer at least once. That includes importing a live database into Terraform, building the new stack beside the old one, shifting traffic with weighted DNS, and watching a bad deploy roll itself back.

---

## What you're building

**Before (Phase 2):**

```
app.lab.yourdomain.com ──► EC2 (nginx + node, deployed by SSH + git pull) ──► RDS Postgres
```

**After (Phase 10):**

```
                        ┌──────────── GitHub Actions ─────────────┐
 PR ──► test + build    │ merge ──► build once, tag = git SHA ──► ECR
                        │        ──► staging: migrate → rolling deploy → smoke test
                        │        ──► approval ──► prod: migrate → rolling deploy → smoke test
                        └─────────────────────────────────────────┘

app.lab… / staging.lab… ──► Route 53 ──► ALB (HTTPS, host + path rules)
                                           ├─ /api/*  ──► ECS Fargate "api" tasks (autoscaled)
                                           └─ /*      ──► ECS Fargate "web" tasks
                                                             │
                                          Secrets Manager ───┤──► RDS Postgres (same DB as before)
                                          CloudWatch Logs ◄──┘
```

## How the phases map to your Part A answer

| Your design step | Lab phase |
|---|---|
| (the starting point in the brief) | Phase 2: recreate the legacy server and database |
| 1. Make it safe first | Phase 3: audit, snapshots, a tested restore |
| 2. Add CI without touching prod | Phase 4: tests and image builds on every PR |
| 3. Bring existing infrastructure under Terraform | Phase 5: remote state, import the live DB and DNS record |
| 4. Build the new stack in parallel | Phases 6–8: ECS stack, deploy pipeline, Terraform in CI |
| 5. Cut over gradually | Phase 9: weighted DNS, 10% → 50% → 100% |
| 6. Decommission | Phase 10: remove the legacy server and SSH access |

Phase 1 gets the app running on your laptop, and Phase 11 tears everything down.

## Before you start

**Cost.** With everything running (ALB, two small RDS instances, six small Fargate tasks, one EC2 instance, public IPv4 addresses), expect roughly **US$4–6 per day**. Most of it is fixed hourly cost, so work in focused sessions and do Phase 11 when you're done. Don't leave it running for weeks.

**Time.** About a day of hands-on work spread over a few sessions. Most of the waiting is RDS creation (~10 minutes each) and certificate validation.

**Region.** The guide uses `eu-west-1` (Ireland). Any region works; keep it consistent everywhere, including `infra/backend.tf`.

**Conventions.**
- Run commands from the repo root unless a step says `cd infra`.
- Every ID you capture gets appended to `~/.expertlisting-lab.env`. In a new terminal, run `source ~/.expertlisting-lab.env` and you're back where you left off.
- Boxes marked **LAB SHORTCUT** are simplifications you'd do differently in production. They're collected at the end as interview talking points.

---

## Phase 0: Tools, AWS access and DNS

### 0.1 Install tools

You need: AWS CLI v2, Terraform **1.10 or newer** (the CI pipeline pins 1.10.5), Docker, Node.js 22, git, `jq`, and `dig` (`dnsutils` / `bind-tools`).

### 0.2 AWS credentials

Use an IAM user or SSO profile with admin rights **in a sandbox account**, not a work account.

```bash
aws sts get-caller-identity
```

### 0.3 Lab variables

```bash
cat > ~/.expertlisting-lab.env <<'VARS'
export AWS_REGION=eu-west-1
export AWS_DEFAULT_REGION=eu-west-1
export LAB_DOMAIN=lab.yourdomain.com          # a subdomain of the domain you own
export GH_REPO=your-github-user/expertlisting-lab
export EMAIL=you@example.com                  # for Let's Encrypt on the legacy server
VARS
source ~/.expertlisting-lab.env
```

### 0.4 Delegate a lab subdomain to Route 53

Delegating only `lab.yourdomain.com` means nothing you do here can affect your main domain, whoever hosts its DNS.

```bash
ZONE_ID=$(aws route53 create-hosted-zone --name "$LAB_DOMAIN" \
  --caller-reference "lab-$(date +%s)" \
  --query 'HostedZone.Id' --output text | sed 's#/hostedzone/##')
echo "export ZONE_ID=$ZONE_ID" >> ~/.expertlisting-lab.env

aws route53 get-hosted-zone --id "$ZONE_ID" --query 'DelegationSet.NameServers' --output text
```

At your domain's DNS provider, add **four NS records** with host `lab`, one per name server printed above. (If the parent domain is itself in Route 53, create one NS record named `lab` in the parent zone with all four values.)

Check delegation. It can take a few minutes, occasionally longer:

```bash
dig +short NS "$LAB_DOMAIN"     # should list the awsdns name servers
```

Don't continue until this works; certificates in Phases 2 and 6 depend on it.

---

## Phase 1: The app, on your laptop

### 1.1 Create the repo

Create a **public** GitHub repo named `expertlisting-lab`, then unzip the lab files into it and push:

```bash
git init && git add . && git commit -m "Expert Listing lab"
git branch -M main
git remote add origin "https://github.com/$GH_REPO.git"
git push -u origin main
```

Public keeps two things simple: the legacy server can `git clone` without credentials, and GitHub environment approvals are free on public repos. Never commit secrets; `.gitignore` already excludes state files and SSH keys.

Then, in GitHub, go to **Actions**, and **disable** the `deploy` and `terraform` workflows (open each one, then the `···` menu, then **Disable workflow**). They need AWS roles that don't exist yet; you'll enable them in Phases 7 and 8.

### 1.2 What's in the repo

| Path | What it is |
|---|---|
| `api/` | Node/Express API. `/api/health` (liveness, no DB), `/api/info` (build SHA and which backend answered), `/api/listings` (reads Postgres). `migrate.js` applies `migrations/*.sql` once each, under an advisory lock. |
| `web/` | Static page served by nginx. It shows which backend and which build answered your request, which makes deploys and cutover visible. |
| `legacy/` | The "before" world: EC2 user-data, nginx config, systemd units, and `deploy.sh` (git pull + restart). |
| `infra/` | Terraform: `modules/env` is one environment (services, task definitions, target groups, listener rules, autoscaling); `staging.tf` and `prod.tf` instantiate it. |
| `scripts/` | `ecs-deploy.sh` (migrate, then rolling deploy, then verify), `smoke-test.sh`, `watch-cutover.sh`. |
| `.github/workflows/` | `ci.yml` (PRs), `deploy.yml` (app pipeline), `terraform.yml` (infra pipeline). |

### 1.3 Run it locally

```bash
docker compose up --build
```

Open http://localhost:8080. You should see **Running locally** and six listings. The API container ran `migrate.js` before starting, which is the same migration mechanism production uses.

```bash
cd api && npm ci && npm test && cd ..
```

`Ctrl+C` and `docker compose down` when done.

---

## Phase 2: Recreate the "before" world

The brief's platform: a web app and API on a single server, a managed Postgres database, deploys by SSH and `git pull`. You'll build exactly that **by hand with the CLI**, because the point of Phase 5 is adopting infrastructure that Terraform didn't create.

### 2.1 Network and security groups

```bash
VPC_ID=$(aws ec2 describe-vpcs --filters Name=is-default,Values=true --query 'Vpcs[0].VpcId' --output text)
SUBNET_IDS=$(aws ec2 describe-subnets --filters Name=vpc-id,Values="$VPC_ID" Name=default-for-az,Values=true \
  --query 'Subnets[].SubnetId' --output text)
MY_IP=$(curl -s https://checkip.amazonaws.com)

WEB_SG=$(aws ec2 create-security-group --group-name legacy-web-sg \
  --description "Legacy app server" --vpc-id "$VPC_ID" --query GroupId --output text)
aws ec2 authorize-security-group-ingress --group-id "$WEB_SG" --protocol tcp --port 22  --cidr "$MY_IP/32"
aws ec2 authorize-security-group-ingress --group-id "$WEB_SG" --protocol tcp --port 80  --cidr 0.0.0.0/0
aws ec2 authorize-security-group-ingress --group-id "$WEB_SG" --protocol tcp --port 443 --cidr 0.0.0.0/0

DB_SG=$(aws ec2 create-security-group --group-name legacy-db-sg \
  --description "Existing prod database" --vpc-id "$VPC_ID" --query GroupId --output text)
aws ec2 authorize-security-group-ingress --group-id "$DB_SG" --protocol tcp --port 5432 --source-group "$WEB_SG"

echo "export VPC_ID=$VPC_ID WEB_SG=$WEB_SG DB_SG=$DB_SG" >> ~/.expertlisting-lab.env
```

If the account has no default VPC, run `aws ec2 create-default-vpc` first.

### 2.2 The "existing" production database

```bash
aws rds create-db-subnet-group --db-subnet-group-name legacy-db-subnets \
  --db-subnet-group-description "Existing prod DB subnets" --subnet-ids $SUBNET_IDS

aws rds create-db-instance \
  --db-instance-identifier expertlisting-prod-db \
  --engine postgres \
  --db-instance-class db.t4g.micro \
  --allocated-storage 20 --storage-type gp3 --storage-encrypted \
  --db-name expertlisting \
  --master-username app --manage-master-user-password \
  --db-subnet-group-name legacy-db-subnets \
  --vpc-security-group-ids "$DB_SG" \
  --no-publicly-accessible \
  --backup-retention-period 7 \
  --deletion-protection
```

`--manage-master-user-password` makes RDS generate the password and keep it in Secrets Manager. Nobody ever types it, and ECS will read it from there later. Creation takes about 10 minutes; carry on meanwhile.

### 2.3 The legacy server

```bash
AMI_ID=$(aws ssm get-parameter \
  --name /aws/service/canonical/ubuntu/server/24.04/stable/current/amd64/hvm/ebs-gp3/ami-id \
  --query Parameter.Value --output text)

aws ec2 create-key-pair --key-name legacy-key --query KeyMaterial --output text > legacy-key.pem
chmod 400 legacy-key.pem

INSTANCE_ID=$(aws ec2 run-instances --image-id "$AMI_ID" --instance-type t3.micro \
  --key-name legacy-key --security-group-ids "$WEB_SG" \
  --user-data file://legacy/user-data.sh \
  --tag-specifications 'ResourceType=instance,Tags=[{Key=Name,Value=expertlisting-legacy}]' \
  --query 'Instances[0].InstanceId' --output text)
aws ec2 wait instance-running --instance-ids "$INSTANCE_ID"

EIP_ALLOC=$(aws ec2 allocate-address --domain vpc --query AllocationId --output text)
aws ec2 associate-address --instance-id "$INSTANCE_ID" --allocation-id "$EIP_ALLOC"
LEGACY_IP=$(aws ec2 describe-addresses --allocation-ids "$EIP_ALLOC" --query 'Addresses[0].PublicIp' --output text)

echo "export INSTANCE_ID=$INSTANCE_ID EIP_ALLOC=$EIP_ALLOC LEGACY_IP=$LEGACY_IP" >> ~/.expertlisting-lab.env
```

### 2.4 DNS for the legacy server

```bash
cat > /tmp/legacy-dns.json <<JSON
{ "Changes": [ { "Action": "CREATE", "ResourceRecordSet": {
    "Name": "app.${LAB_DOMAIN}", "Type": "A",
    "SetIdentifier": "legacy", "Weight": 100, "TTL": 60,
    "ResourceRecords": [ { "Value": "${LEGACY_IP}" } ] } } ] }
JSON
aws route53 change-resource-record-sets --hosted-zone-id "$ZONE_ID" --change-batch file:///tmp/legacy-dns.json
```

> **Why weighted from the start?** To keep the lab simple. In a real migration the existing record would be a plain A record. Before cutover you'd convert it with **one** change batch that deletes the simple record and creates the weighted one. Route 53 applies a batch atomically, so there's no moment without an answer. You'd also lower its TTL a day or two in advance so the change propagates quickly.

### 2.5 Configure the server

Wait for the database, then fetch its endpoint and generated password:

```bash
aws rds wait db-instance-available --db-instance-identifier expertlisting-prod-db
DB_HOST=$(aws rds describe-db-instances --db-instance-identifier expertlisting-prod-db \
  --query 'DBInstances[0].Endpoint.Address' --output text)
DB_SECRET_ARN=$(aws rds describe-db-instances --db-instance-identifier expertlisting-prod-db \
  --query 'DBInstances[0].MasterUserSecret.SecretArn' --output text)
DB_PASSWORD=$(aws secretsmanager get-secret-value --secret-id "$DB_SECRET_ARN" \
  --query SecretString --output text | jq -r .password)
echo "export DB_HOST=$DB_HOST DB_SECRET_ARN=$DB_SECRET_ARN" >> ~/.expertlisting-lab.env
```

Clone the repo on the server and write its config file. This is the "credentials in an env file on a box" setup the migration will get rid of.

```bash
SSH="ssh -i $(pwd)/legacy-key.pem -o StrictHostKeyChecking=accept-new ubuntu@$LEGACY_IP"
echo "export SSH=\"$SSH\"" >> ~/.expertlisting-lab.env

$SSH "cloud-init status --wait && git clone https://github.com/${GH_REPO}.git /opt/expertlisting"

$SSH "sudo tee /etc/expertlisting.env >/dev/null && sudo chmod 600 /etc/expertlisting.env" <<ENVFILE
PORT=3000
DB_HOST=${DB_HOST}
DB_PORT=5432
DB_NAME=expertlisting
DB_USER=app
DB_PASSWORD=${DB_PASSWORD}
SERVED_BY=legacy
ENVFILE
```

Confirm DNS resolves to the server (Let's Encrypt needs it), then run the one-time setup. It installs the nginx config and systemd units, does the first deploy (which runs the migrations), and gets a TLS certificate.

```bash
dig +short "app.$LAB_DOMAIN"      # must print $LEGACY_IP
$SSH "sudo /opt/expertlisting/legacy/setup.sh app.${LAB_DOMAIN} ${EMAIL}"
```

Open `https://app.lab.yourdomain.com`. You should see **Served by the legacy server** and the six listings.

### 2.6 Feel the pain

Change something visible, for example the text in `<p class="brand">` in `web/public/index.html`. Commit and push.

In one terminal, watch the site:

```bash
while true; do printf "%s " "$(curl -s -o /dev/null -w '%{http_code}' "https://app.$LAB_DOMAIN/api/health")"; sleep 0.2; done
```

In another, deploy the way Expert Listing does today:

```bash
$SSH /opt/expertlisting/legacy/deploy.sh
```

You may catch a few `502`s while node restarts. More importantly, notice what's missing: no tests ran, nothing records who deployed what, one bad commit goes straight to production, and rollback means SSH-ing in and checking out an old commit by hand. This is the problem your design solves.

---

## Phase 3: Make it safe first

*Design step 1. Nothing changes for users; you just make sure you can recover.*

### 3.1 Audit the box

Find out everything the server does before you replace it. These are the things that bite during migrations:

```bash
$SSH 'crontab -l; sudo crontab -l; systemctl list-timers --no-pager'   # scheduled jobs?
$SSH 'sudo ss -tlnp'                                                    # what's listening?
$SSH 'ls -la /var/www/expertlisting /opt/expertlisting'                 # anything written to local disk?
$SSH 'sudo cat /etc/expertlisting.env | cut -d= -f1'                    # which config keys exist (not values)
```

This app keeps nothing on local disk. On the real Expert Listing platform, uploaded **property photos** stored on the server's disk would be the obvious trap. They must move to S3 before any cutover, because a container's disk disappears when the task is replaced.

### 3.2 Snapshots

```bash
aws rds create-db-snapshot --db-instance-identifier expertlisting-prod-db \
  --db-snapshot-identifier expertlisting-prod-pre-migration
AMI_BACKUP=$(aws ec2 create-image --instance-id "$INSTANCE_ID" --name expertlisting-legacy-backup \
  --no-reboot --query ImageId --output text)
echo "export AMI_BACKUP=$AMI_BACKUP" >> ~/.expertlisting-lab.env
```

### 3.3 Prove a restore works

A backup you've never restored is a hope, not a backup. Restore to a temporary instance:

```bash
aws rds restore-db-instance-to-point-in-time \
  --source-db-instance-identifier expertlisting-prod-db \
  --target-db-instance-identifier restore-test \
  --use-latest-restorable-time \
  --db-instance-class db.t4g.micro \
  --db-subnet-group-name legacy-db-subnets \
  --vpc-security-group-ids "$DB_SG" \
  --no-publicly-accessible
aws rds wait db-instance-available --db-instance-identifier restore-test
```

To query it, give the copy a throwaway password and count rows from the legacy server, which is allowed through `legacy-db-sg`:

```bash
aws rds modify-db-instance --db-instance-identifier restore-test \
  --no-manage-master-user-password --master-user-password 'RestoreTest-123' --apply-immediately
sleep 60
RESTORE_HOST=$(aws rds describe-db-instances --db-instance-identifier restore-test \
  --query 'DBInstances[0].Endpoint.Address' --output text)
$SSH "PGPASSWORD='RestoreTest-123' psql 'host=$RESTORE_HOST dbname=expertlisting user=app sslmode=require' -c 'SELECT count(*) FROM listings'"
```

If the password change is rejected because the restored copy manages its password differently, drop `--no-manage-master-user-password` and retry. Seeing `6` means the restore works. Clean up:

```bash
aws rds delete-db-instance --db-instance-identifier restore-test --skip-final-snapshot
```

### 3.4 Know the secret rotation gotcha

RDS-managed passwords rotate automatically, every 7 days by default. When that happens, the legacy server's env file is stale and the API loses its database. ECS tasks read the secret only when they start, so running tasks go stale too until they're replaced. For the lab, stretch the schedule:

```bash
aws secretsmanager rotate-secret --secret-id "$DB_SECRET_ARN" \
  --rotation-rules AutomaticallyAfterDays=90 --no-rotate-immediately
```

If this happens anyway: rewrite `/etc/expertlisting.env` as in 2.5, restart the legacy API, and run `aws ecs update-service --force-new-deployment` for the ECS services. In production you'd give the app its own database user rather than the master user; it's worth saying so in an interview.

---

## Phase 4: CI on every pull request

*Design step 2. Every change gets tested and built before it merges, with no production access needed.*

`ci.yml` runs on pull requests that touch `api/` or `web/`: install, `npm test`, then `docker build` for both images (built, not pushed).

Try it: create a branch, change something in `api/`, push, and open a PR. Watch both checks go green. Then change the health route to return `500`, push again, and watch the test fail. That bad change can no longer reach production. Revert it.

Optionally, protect `main` (**Settings → Branches**) so PRs need passing checks. Leave that for later if you want to push straight to `main` during the lab.

> **Quick win in real life:** on Expert Listing you'd also replace manual SSH deploys with a CI job that runs the same deploy script. That makes deploys repeatable and logged within the first week. The lab skips it because the server is about to go away.

---

## Phase 5: Terraform foundation, and adopting what already exists

*Design step 3. The goal: Terraform takes ownership of the live database and DNS record, and its first plan changes nothing.*

### 5.1 State bucket

```bash
STATE_BUCKET="expertlisting-tfstate-$(aws sts get-caller-identity --query Account --output text)"
aws s3api create-bucket --bucket "$STATE_BUCKET" \
  --create-bucket-configuration LocationConstraint="$AWS_REGION"   # omit this line in us-east-1
aws s3api put-bucket-versioning --bucket "$STATE_BUCKET" --versioning-configuration Status=Enabled
aws s3api put-public-access-block --bucket "$STATE_BUCKET" --public-access-block-configuration \
  BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true
echo "export STATE_BUCKET=$STATE_BUCKET" >> ~/.expertlisting-lab.env
```

Versioning means a corrupted state file can be rolled back. Locking uses Terraform's S3-native lock file (`use_lockfile = true`), so no DynamoDB table is needed.

### 5.2 Fill in the configuration

In `infra/backend.tf`, set `bucket` to `$STATE_BUCKET` and `region` to your region.

In `infra/terraform.tfvars`, fill in the values:

```bash
echo "zone_id=$ZONE_ID  legacy_ip=$LEGACY_IP  legacy_db_sg_id=$DB_SG"
aws rds describe-db-instances --db-instance-identifier expertlisting-prod-db \
  --query 'DBInstances[0].EngineVersion' --output text      # e.g. 17.4 -> db_engine_version = "17"
```

Set `github_repo` to exactly how GitHub spells it (the OIDC trust is case-sensitive).

### 5.3 Import, and read the plan carefully

`infra/imports.tf` tells Terraform to adopt the database and the legacy DNS record. `prod.tf` describes the database as it really is. Start with a plan limited to those two resources:

```bash
cd infra
terraform fmt -recursive
terraform init
terraform plan -target=aws_db_instance.prod -target=aws_route53_record.prod_legacy
```

What you want to see is `Plan: 2 to import, 0 to add, 0 to change, 0 to destroy`. A few in-place "changes" are expected and harmless, because they are Terraform-only settings or tags rather than real infrastructure changes:
- `tags_all` gaining `Project` and `ManagedBy` (from `default_tags` in the provider)
- `skip_final_snapshot`, `final_snapshot_identifier`, `apply_immediately` or `manage_master_user_password` appearing as new values

Anything else that would change, especially anything that says **must be replaced**, means the HCL doesn't match reality. **Fix the HCL, never the database.** Adjust `prod.tf` until the plan matches. This is the core discipline of adopting live infrastructure.

When it looks right:

```bash
terraform apply -target=aws_db_instance.prod -target=aws_route53_record.prod_legacy
rm imports.tf          # import blocks are one-time instructions
terraform plan -target=aws_db_instance.prod -target=aws_route53_record.prod_legacy   # expect "No changes"
```

(Terraform warns that `-target` is for exceptional situations. Adopting live resources one at a time is one of them.)

### 5.4 Check the safety net

```bash
terraform plan -destroy -target=aws_db_instance.prod
```

This should **fail** with an error about `prevent_destroy`. A mistake in Terraform can't delete production data. Deletion protection on the instance itself is a second, independent layer.

Commit and push `infra/` (the `terraform` workflow is disabled, so nothing runs yet).

---

## Phase 6: Build the new stack in parallel

*Design step 4. Everything new is built beside the legacy server and connected to the same database. Public traffic doesn't move yet.*

### 6.1 Image registry first

ECS services need an image to start, so create the ECR repositories on their own, then push a first image:

```bash
terraform apply -target='aws_ecr_repository.app'
cd ..

REGISTRY="$(aws sts get-caller-identity --query Account --output text).dkr.ecr.$AWS_REGION.amazonaws.com"
aws ecr get-login-password | docker login --username AWS --password-stdin "$REGISTRY"
for svc in api web; do
  docker build --platform linux/amd64 --build-arg APP_VERSION=initial -t "$REGISTRY/expertlisting/$svc:initial" "./$svc"
  docker push "$REGISTRY/expertlisting/$svc:initial"
done
```

`--platform linux/amd64` matters on Apple Silicon Macs: the tasks run on x86, and an arm64 image fails to start with `exec format error`.

### 6.2 Plan and apply everything

```bash
cd infra
terraform plan -out=tfplan
```

Read the summary before applying. You should see around 60 resources **to add** and nothing to change or destroy. If the plan wants to change or replace `aws_db_instance.prod`, stop and go back to 5.3.

What gets created:
- **Shared:** ECS cluster, ALB with HTTP→HTTPS redirect, wildcard ACM certificate (validated through Route 53), ECR lifecycle rules, the GitHub OIDC provider and two roles (deploy and Terraform).
- **Staging:** a new small database, plus the `env` module: two services, task definitions, target groups, listener rules for `staging.<lab_domain>`, log groups and autoscaling.
- **Prod:** the same `env` module for `app.<lab_domain>`, pointed at the **existing** database, with one new security group rule letting the prod tasks reach it.
- **DNS:** `staging.<lab_domain>` pointing at the ALB, and a second weighted record for `app.<lab_domain>` pointing at the ALB **with weight 0**.

```bash
terraform apply tfplan
```

This takes 10–15 minutes, mostly the staging database and certificate validation. Commit and push `infra/` afterwards.

### 6.3 Look at prod on ECS, before any user can

Public DNS still sends everyone to the legacy server. To reach the new stack directly, `curl --connect-to` connects to the ALB while keeping the real hostname for TLS and routing:

```bash
ALB=$(terraform output -raw alb_dns_name)
echo "export ALB=$ALB" >> ~/.expertlisting-lab.env

curl -s --connect-to "app.$LAB_DOMAIN:443:$ALB:443" "https://app.$LAB_DOMAIN/api/info" | jq     # servedBy: ecs-prod
curl -s --connect-to "app.$LAB_DOMAIN:443:$ALB:443" "https://app.$LAB_DOMAIN/api/listings" | jq length   # 6
curl -s "https://app.$LAB_DOMAIN/api/info" | jq                                                  # servedBy: legacy
```

The prod containers already return the six listings. They're reading the same database the legacy server uses, which is why this migration needs no data migration at all.

`https://staging.lab.yourdomain.com` opens in a browser and shows **Staging on ECS Fargate**, but listings fail to load. That's expected: the staging database is empty until the pipeline runs its first migration in Phase 7.

### 6.4 Look around the console

In **ECS → Clusters → expertlisting**, open each service and look at Tasks, Deployments, and Logs. In **EC2 → Target Groups**, each target group should show healthy targets. It's worth knowing where these screens are before something goes wrong.

---

## Phase 7: The deployment pipeline

### 7.1 Connect GitHub to AWS

In the repo's **Settings**:

1. **Environments → New environment** `staging`. No protection rules.
2. **Environments → New environment** `production`. Tick **Required reviewers** and add yourself. Under **Deployment branches**, choose **Selected branches** and add `main`.
3. **Secrets and variables → Actions → Variables**, add:

| Variable | Value |
|---|---|
| `AWS_REGION` | your region |
| `LAB_DOMAIN` | `lab.yourdomain.com` |
| `AWS_DEPLOY_ROLE_ARN` | `terraform output -raw github_deploy_role_arn` |
| `AWS_TERRAFORM_ROLE_ARN` | `terraform output -raw github_terraform_role_arn` |

These are variables, not secrets. The pipeline uses no AWS keys at all: each job gets a short-lived OIDC token from GitHub and exchanges it for temporary credentials. The roles' trust policies only accept tokens from this repo's `main` branch, its `staging` and `production` environments, and (for the Terraform role) pull requests.

4. **Actions → deploy → Enable workflow.**

### 7.2 First deploy

Go to **Actions → deploy → Run workflow** on `main`, and follow along:

1. **test** runs the unit tests.
2. **build** builds both images once, tagged with the commit SHA, and pushes them to ECR. Tags are immutable, so that SHA will always mean exactly this image.
3. **deploy-staging** runs `scripts/ecs-deploy.sh staging <sha>`, which:
   - copies the latest task definition revisions and swaps in the new image,
   - runs `migrate.js` as a one-off Fargate task **with the new image**, before any traffic moves (this first run creates and seeds the staging tables),
   - updates both services and waits for the rolling deploy to settle,
   - fails if the circuit breaker rolled back instead.

   Then `smoke-test.sh` checks, through the ALB, that the API and web both report the new SHA and listings load.
4. **deploy-prod** waits. Open the run, click **Review deployments**, approve **production**. It repeats step 3 for prod. The migration step reports nothing to apply, because the legacy server already ran them.

Reload the staging site: listings appear, and the build SHA matches the commit.

> **Who owns what.** Terraform owns the *shape* of each task definition: CPU, memory, environment variables, secrets, roles. The pipeline owns the *image*. The services ignore `task_definition` changes in Terraform, so an infra apply never rolls back a deploy. The trade-off: if you change a task definition in Terraform, it takes effect on the next pipeline deploy, which copies the newest revision.

### 7.3 Watch a zero-downtime rolling deploy

Start this loop against staging:

```bash
while true; do printf "%s " "$(curl -s -o /dev/null -w '%{http_code}' "https://staging.$LAB_DOMAIN/api/health")"; sleep 0.2; done
```

Push any visible change to `web/public/index.html` on `main`. While staging deploys, watch the service's **Deployments** tab in the ECS console. New tasks start next to the old ones (`maximum_percent = 200`), register with the target group, pass health checks, and only then do old tasks drain (30-second deregistration delay) and stop. The loop should print nothing but `200`. Compare that with Phase 2.6.

### 7.4 Break it on purpose

Add this line near the top of `api/src/server.js`:

```js
if ((process.env.SERVED_BY || '').startsWith('ecs')) throw new Error('simulated bad config');
```

The unit tests don't load `server.js`, so CI passes. That's deliberate: this is the kind of failure that only shows up in the real environment. Push to `main` and watch:

- Staging migrations succeed (they use `migrate.js`, not `server.js`).
- New API tasks crash on start. After a few failures, the **deployment circuit breaker** rolls the service back to the previous task definition.
- `ecs-deploy.sh` notices the rollback and fails the job. **deploy-prod never runs.**
- The staging site keeps serving the previous build throughout.

In CloudWatch Logs (`/ecs/expertlisting-staging-api`), find the `simulated bad config` error. That's your root cause. Remove the line, push, and the pipeline goes green.

### 7.5 A safe schema change (expand, then contract)

During the migration, two versions of the code share one database: the legacy server's and the ECS tasks'. The same thing happens in every rolling deploy, where old and new tasks overlap. Schema changes must work for both.

Add `api/migrations/003_add_verified.sql`:

```sql
ALTER TABLE listings ADD COLUMN IF NOT EXISTS verified BOOLEAN NOT NULL DEFAULT false;
UPDATE listings SET verified = true WHERE city IN ('Lagos', 'Abuja');
```

In `api/src/app.js`, add `verified` to the `SELECT` column list. In `web/public/index.html`, after the line that sets `.meta`, add:

```js
if (l.verified) li.querySelector('.meta').textContent += ', verified';
```

Push and approve prod. The migration runs against the **shared** prod database while the legacy server still serves 100% of public traffic on old code. Load `https://app.lab.yourdomain.com` (legacy): it still works, because adding a column breaks nothing. Had the migration renamed or dropped a column, the legacy server and any old tasks mid-rollout would start returning 500s. The rule is to **expand** first, and **contract** (remove the old thing) only in a later release, once nothing uses it.

### 7.6 Roll back

Open **Actions → deploy**, pick an earlier successful run, and choose **Re-run all jobs**. The build step finds the images already in ECR and skips building, and the old SHA rolls out through staging and prod again. Rolling back is just deploying an older version.

Notice what didn't roll back: the database. Migrations only go forward, which is exactly why they have to be backward compatible.

### 7.7 Autoscaling (optional, but good preparation for Part C)

Staging has a CPU-burning endpoint and can scale from 1 to 3 API tasks at 60% average CPU. Install [`hey`](https://github.com/rakyll/hey) (`brew install hey` or `go install github.com/rakyll/hey@latest`), then:

```bash
hey -z 4m -c 40 "https://staging.$LAB_DOMAIN/api/burn?ms=100"
```

In another terminal:

```bash
watch -n 10 "aws ecs describe-services --cluster expertlisting --services expertlisting-staging-api \
  --query 'services[0].[desiredCount,runningCount]' --output text"
```

It takes a few minutes of sustained CPU before the alarm fires and tasks are added, and much longer to scale back in (that caution is deliberate). This delay is the Part C point: for a campaign you know is coming, **raise the minimum ahead of time** instead of waiting for reactive scaling. In Terraform you'd bump `api_min_count` for the campaign week; a scheduled action works too:

```bash
aws application-autoscaling put-scheduled-action --service-namespace ecs \
  --resource-id service/expertlisting/expertlisting-prod-api \
  --scalable-dimension ecs:service:DesiredCount \
  --scheduled-action-name campaign-week \
  --schedule "at(2026-10-05T06:00:00)" \
  --scalable-target-action MinCapacity=6,MaxCapacity=12
```

---

## Phase 8: Terraform through pull requests

Until now you applied Terraform from your laptop. From here on, infrastructure changes go through the same review flow as code.

Enable **Actions → terraform**. Then, on a branch, change `api_max_count = 3` to `4` in `infra/staging.tf`, run `terraform fmt -recursive`, and open a PR.

- The **plan** job runs `fmt -check`, `validate` and `plan`. Read the plan in the job log: one in-place change to the autoscaling target.
- Merge. The **apply** job waits for the `production` approval, then applies.

The same approval gate protects both application deploys and infrastructure changes.

> **Worth knowing:** the plan you reviewed on the PR isn't guaranteed to be what gets applied after merge if something changed in between. Teams handle that by saving the plan as an artifact and applying exactly that file, or by using a tool such as Atlantis or HCP Terraform. For a single-owner platform, plan-on-PR plus a gated apply is a reasonable place to start.

---

## Phase 9: Cut over with weighted DNS

*Design step 5. Move real traffic in steps, with a one-line rollback at every step.*

`app.<lab_domain>` now has two weighted records: `legacy` (the EC2 IP) and `ecs` (the ALB). Route 53 answers each DNS query with one of them in proportion to their weights. `legacy_weight` and `ecs_weight` in `terraform.tfvars` are the dial, and you'll turn it through pull requests.

### 9.1 Pre-flight

- The latest deploy is green, and prod on ECS reports the current SHA (`scripts/smoke-test.sh "app.$LAB_DOMAIN" <sha>` from your laptop works too).
- Both backends serve the same data (6.3).
- Baseline, which should be all legacy:

```bash
./scripts/watch-cutover.sh "app.$LAB_DOMAIN" "$ZONE_ID" "$LEGACY_IP" 100
```

- In another terminal, watch real requests arriving at the legacy server:

```bash
$SSH 'sudo tail -f /var/log/nginx/access.log'
```

### 9.2 Turn the dial

For each step, open a PR changing the two weights in `infra/terraform.tfvars`, check that the plan touches **only** the two DNS records, merge, and approve. Then wait a minute (the TTL is 60 seconds) and re-run `watch-cutover.sh`.

| Step | `legacy_weight` | `ecs_weight` | Expect from `watch-cutover.sh` |
|---|---|---|---|
| Canary | 90 | 10 | about 10 of 100 answers are the ALB |
| Half | 50 | 50 | roughly an even split |
| Full | 0 | 100 | all ALB |

Between steps, check the ALB side: in CloudWatch, the ALB's `RequestCount` and `HTTPCode_Target_5XX_Count`, per target group. Reload `https://app.lab.yourdomain.com` a few times; the headline shows which backend answered you.

Two things to understand:
- **Weights apply per DNS answer, not per request.** Your laptop, your ISP's resolver and your browser cache answers, so an individual user sticks to one backend for a while and the real split is lumpy. That's why the TTL is low and why the legacy server stays up for a while after 100%.
- **The ECS record has `evaluate_target_health = true`.** If the ALB has no healthy targets, Route 53 stops returning it, and the legacy server takes the traffic automatically.

### 9.3 Rollback drill

At the 10% step, practise going back: a PR setting `ecs_weight = 0`, merge, approve. That's the entire rollback, and it takes about as long as the TTL. Then continue to 100%.

During cutover, don't deploy to the legacy server. Both backends serve the same data, but you want only one thing changing at a time.

---

## Phase 10: Decommission

*Design step 6. In real life, give 100% ECS a week of normal traffic first. For the lab, an hour of quiet on the nginx access log is enough.*

### 10.1 Remove the legacy DNS record

On a branch, delete the whole `resource "aws_route53_record" "prod_legacy"` block from `infra/prod.tf` (you can leave the `legacy_*` variables). PR, check the plan shows **1 to destroy** (that record, nothing else), merge, approve. The `ecs` weighted record alone now answers for `app.<lab_domain>`.

### 10.2 Remove the server

```bash
aws ec2 revoke-security-group-ingress --group-id "$DB_SG" --protocol tcp --port 5432 --source-group "$WEB_SG"
aws ec2 terminate-instances --instance-ids "$INSTANCE_ID"
aws ec2 wait instance-terminated --instance-ids "$INSTANCE_ID"
aws ec2 release-address --allocation-id "$EIP_ALLOC"
aws ec2 delete-security-group --group-id "$WEB_SG"
aws ec2 delete-key-pair --key-name legacy-key && rm -f legacy-key.pem
```

The first command revokes the legacy server's database access. It has to go first, because a security group that another group's rules still reference can't be deleted.

### 10.3 What you've ended with

- No server anyone can SSH into. Production access is the pipeline, and changes are reviewed PRs. (For break-glass debugging, ECS Exec gives you a shell in a running task without opening a port.)
- Every deploy is a known image SHA, tested, migrated, rolled out with health checks, verified, and reversible by re-running an older build.
- The whole platform is described in Terraform, including the database that existed before Terraform did.

---

## Phase 11: Tear down

Do this from your laptop with admin credentials. The prod database is protected twice, so remove both protections deliberately:

1. In `infra/prod.tf`, on `aws_db_instance.prod`: set `deletion_protection = false`, set `skip_final_snapshot = true`, delete `final_snapshot_identifier`, and delete the whole `lifecycle { prevent_destroy = true }` block.
2. Then:

```bash
cd infra
terraform apply            # turns off deletion protection
terraform destroy          # removes everything Terraform manages
cd ..
```

If `terraform destroy` complains about the GitHub OIDC provider and you share it with another project, remove it from state first (`terraform state rm aws_iam_openid_connect_provider.github`) and destroy again.

3. Remove what was created by hand:

```bash
aws ec2 delete-security-group --group-id "$DB_SG"
aws rds delete-db-subnet-group --db-subnet-group-name legacy-db-subnets
aws rds delete-db-snapshot --db-snapshot-identifier expertlisting-prod-pre-migration
SNAP=$(aws ec2 describe-images --image-ids "$AMI_BACKUP" \
  --query 'Images[0].BlockDeviceMappings[0].Ebs.SnapshotId' --output text)
aws ec2 deregister-image --image-id "$AMI_BACKUP"
aws ec2 delete-snapshot --snapshot-id "$SNAP"
```

If you skipped Phase 10, run 10.2 first, and delete the legacy DNS record in the Route 53 console.

4. Empty and delete the state bucket (versioned buckets are easiest to empty with the console's **Empty** button), then delete the hosted zone and remove the `lab` NS records at your registrar:

```bash
aws s3 rb "s3://$STATE_BUCKET"
aws route53 delete-hosted-zone --id "$ZONE_ID"
```

5. The next day, check **Billing → Bills** for anything still accruing.

---

## Lab shortcuts vs production

Each of these is a good answer to "what would you do differently for real?"

| In the lab | In production |
|---|---|
| Default VPC; tasks in public subnets with public IPs (still only reachable from the ALB) | Dedicated VPC; tasks in private subnets, outbound via NAT gateway or VPC endpoints for ECR, Secrets Manager and CloudWatch |
| App connects as the RDS master user | A dedicated least-privilege database user for the app; the master credential is break-glass only |
| `rejectUnauthorized: false` on the DB TLS connection | Verify the server certificate using the RDS CA bundle |
| One Terraform state for everything | Separate states per environment and for shared foundations, so a staging change can't touch prod |
| Terraform CI role has AdministratorAccess | Read-only role for plans, scoped role for applies |
| Plan on PR, re-plan and apply on merge | Apply the exact saved plan, or use Atlantis or HCP Terraform |
| Staging and prod share a cluster, ALB and account | Separate AWS accounts per environment once the team grows |
| Liveness health check only | Add a readiness check that includes dependencies, plus alarms on 5xx rate, latency and task restarts, feeding an on-call channel |
| No WAF | AWS WAF on the ALB with managed rule sets and rate limiting |

## What this lab lets you say with confidence

- *"I kept the existing managed database and pointed the new stack at it, so there was no data migration. The risky part became a DNS weight change you can reverse in a minute."*
- *"The first Terraform plan against production must show no changes. If it doesn't, you fix the code, never the infrastructure."*
- *"Images are built once, tagged with the commit SHA and promoted. Staging and prod run the identical artifact."*
- *"Migrations run as a one-off task with the new image before traffic shifts, and they must be backward compatible, because old and new code share the database during every rollout."*
- *"The circuit breaker rolls back a bad deploy automatically, and the pipeline treats a rollback as a failure, so prod never sees it."*
- *"For a known traffic spike I'd raise the minimum task count in advance rather than trust reactive autoscaling, and load test first. The database is the more likely bottleneck than the containers."*

---

## Troubleshooting

**`dig +short NS lab.yourdomain.com` returns nothing.** The NS records at your registrar are missing, use the wrong host (it should be `lab`, not the full name at most registrars), or haven't propagated. ACM validation and Let's Encrypt both fail until this works.

**Legacy API returns 500s on `/api/listings`.** Check `journalctl -u expertlisting-api -u expertlisting-migrate` on the server. A password authentication failure means the env file is wrong or the secret rotated (3.4). If the password contains characters that confuse systemd, wrap the value in double quotes in `/etc/expertlisting.env`.

**Terraform: `EntityAlreadyExists` for the OIDC provider.** Your account already has one from another project. Import it (the command is in the comment at the top of `github-oidc.tf`) and re-run.

**Terraform: `Unable to assume the service linked role` when creating ECS services.** A brand-new account sometimes lacks it. Run `aws iam create-service-linked-role --aws-service-name ecs.amazonaws.com` and apply again.

**Tasks stop with `CannotPullContainerError`.** The image tag doesn't exist in ECR (did 6.1 push `initial`?), or the task has no route to ECR (the lab relies on `assign_public_ip = true`).

**Tasks stop with `ResourceInitializationError` mentioning secrets.** The execution role can't read the database secret, or the secret ARN changed. Check `/ecs/...` logs and the `read-db-secret` policy.

**Tasks run but targets are unhealthy.** Check that the container port matches the target group (3000 for api, 80 for web), that the health path returns 200 (`/api/health`, `/`), and that the tasks' security group allows the ALB security group.

**Tasks exit immediately with `exec format error`.** The image was built for arm64. Rebuild with `--platform linux/amd64`.

**GitHub Actions: `Not authorized to perform sts:AssumeRoleWithWebIdentity`.** The token's subject didn't match the trust policy. Check that `github_repo` matches the repo name exactly (including case), that the job runs on `main` or in an environment named exactly `staging` or `production`, and that `permissions: id-token: write` is present.

**The deploy job hangs at "Waiting for the rolling deployment to settle".** New tasks are failing and the circuit breaker is counting failures, which takes a few minutes. Check the service's **Events** tab and the task logs.

**`terraform fmt -check` fails in CI.** Run `terraform fmt -recursive` in `infra/` and commit.
