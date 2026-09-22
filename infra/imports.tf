# Adopt resources that were created by hand (Phase 5). Delete this file after the
# import has been applied; import blocks are one-time instructions.
import {
  to = aws_db_instance.prod
  id = "expertlisting-prod-db"
}

import {
  to = aws_route53_record.prod_legacy
  id = "${var.zone_id}_app.${var.lab_domain}_A_legacy"
}
