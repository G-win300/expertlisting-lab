# Fill these in as you go through the guide.
aws_region        = "eu-west-1"
lab_domain        = "lab.yourdomain.com"
zone_id           = "Z0000000000000000000"
github_repo       = "your-github-user/expertlisting-lab"
legacy_ip         = "0.0.0.0"
legacy_db_sg_id   = "sg-00000000000000000"
db_engine_version = "17"

# Cutover dial (Phase 9). Change these through pull requests.
legacy_weight = 100
ecs_weight    = 0
