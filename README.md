# Expert Listing lab: Part A, hands-on

A web app + API that starts life on one SSH-deployed server with managed Postgres,
and is migrated with zero downtime to ECS Fargate, Terraform and GitHub Actions.

Start with **[GUIDE.md](GUIDE.md)**. It walks through every phase, from recreating
the legacy server to the DNS cutover and teardown.

Quick local run: `docker compose up --build`, then open http://localhost:8080.
