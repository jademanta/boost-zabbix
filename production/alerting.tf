# ---------------------------------------------------------------------------
# Alert delivery: email via SES, Slack via a bot token. Zabbix-side objects
# (media types, notification user, action) are applied by
# ../zabbix/apply-alerting.sh, which reads everything it needs from the SSM
# parameters created here.
# ---------------------------------------------------------------------------

# Domain identity with Easy DKIM. boostability.com's DMARC is p=quarantine and
# SES's default envelope sender is amazonses.com, so only DKIM alignment makes
# alert mail pass DMARC. Publishing the three CNAMEs (output ses_dkim_cnames)
# in Cloudflare also fixes alignment for the account's other SES senders.
resource "aws_sesv2_email_identity" "domain" {
  email_identity = var.alert_from_domain
}

# SMTP credentials = an IAM access key run through SES's derivation. Scoped to
# sending as the one alert address. The key secret is in Terraform state
# (encrypted S3, restricted); accepted because the key can do nothing except
# send mail as netmon@. Rotate by tainting aws_iam_access_key.ses_smtp.
resource "aws_iam_user" "ses_smtp" {
  name = "netmon-zabbix-ses-smtp"
  tags = { Name = "netmon-zabbix-ses-smtp" }
}

resource "aws_iam_user_policy" "ses_smtp" {
  name = "send-as-netmon"
  user = aws_iam_user.ses_smtp.name
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["ses:SendRawEmail", "ses:SendEmail"]
      Resource = "*"
      Condition = {
        StringEquals = { "ses:FromAddress" = var.alert_from_address }
      }
    }]
  })
}

resource "aws_iam_access_key" "ses_smtp" {
  user = aws_iam_user.ses_smtp.name
}

# --- Parameters the Zabbix host reads (instance role, see iam.tf) ----------
resource "aws_ssm_parameter" "smtp_username" {
  name  = "/netmon-zabbix/smtp/username"
  type  = "SecureString"
  value = aws_iam_access_key.ses_smtp.id
}

resource "aws_ssm_parameter" "smtp_password" {
  name  = "/netmon-zabbix/smtp/password"
  type  = "SecureString"
  value = aws_iam_access_key.ses_smtp.ses_smtp_password_v4
}

# Set out-of-band by Jade (values never pass through Terraform or chat):
#   aws --profile boostprod ssm put-parameter --overwrite --name /netmon-zabbix/slack-bot-token --type SecureString --value 'xoxb-...'
#   aws --profile boostprod ssm put-parameter --overwrite --name /netmon-zabbix/api-token       --type SecureString --value '...'
resource "aws_ssm_parameter" "slack_bot_token" {
  name  = "/netmon-zabbix/slack-bot-token"
  type  = "SecureString"
  value = "REPLACE_ME"
  lifecycle {
    ignore_changes = [value]
  }
}

resource "aws_ssm_parameter" "api_token" {
  name        = "/netmon-zabbix/api-token"
  description = "Zabbix API token for the automation user (Users > API tokens)"
  type        = "SecureString"
  value       = "REPLACE_ME"
  lifecycle {
    ignore_changes = [value]
  }
}

# Non-secret settings the apply script reads, so they live in one place.
resource "aws_ssm_parameter" "alerting_settings" {
  name = "/netmon-zabbix/alerting"
  type = "String"
  value = jsonencode({
    smtp_server   = "email-smtp.${var.aws_region}.amazonaws.com"
    smtp_port     = 587
    from_address  = var.alert_from_address
    helo          = var.alert_from_domain
    alert_email   = var.alert_email
    slack_channel = var.slack_channel
    zabbix_url    = "https://${var.fqdn}"
  })
}

output "ses_dkim_cnames" {
  description = "Create these three CNAMEs in Cloudflare (DNS only) for boostability.com. SES flips the identity to verified within minutes of seeing them."
  value = [for t in aws_sesv2_email_identity.domain.dkim_signing_attributes[0].tokens :
    { name = "${t}._domainkey.${var.alert_from_domain}", value = "${t}.dkim.amazonses.com" }
  ]
}
