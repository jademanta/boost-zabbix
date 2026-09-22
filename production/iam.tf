resource "aws_iam_role" "zabbix_host" {
  name        = "netmon-zabbix-host"
  description = "Zabbix host: Session Manager, read the DB secret, grab the EIP at boot"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

# Least privilege on purpose (the account's SsmEc2ManagedInstances profile
# carries SNS full + S3 read everywhere; not reused).
resource "aws_iam_role_policy_attachment" "zabbix_host_ssm" {
  role       = aws_iam_role.zabbix_host.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

# What bootstrap.sh needs beyond SSM:
#  - the RDS master secret (one specific ARN)
#  - associate the one EIP with itself (self-heal: a replacement instance takes
#    the address back without any human step)
#  - sync Caddy's certificate dir to/from the state bucket
#  - mark itself Unhealthy in the ASG when the app is down (scripts/healthcheck.sh)
resource "aws_iam_role_policy" "zabbix_host_bootstrap" {
  name = "netmon-zabbix-bootstrap"
  role = aws_iam_role.zabbix_host.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "ReadDbSecret"
        Effect   = "Allow"
        Action   = ["secretsmanager:GetSecretValue"]
        Resource = aws_db_instance.zabbix.master_user_secret[0].secret_arn
      },
      {
        Sid      = "DescribeForEip"
        Effect   = "Allow"
        Action   = ["ec2:DescribeAddresses", "ec2:DescribeInstances"]
        Resource = "*"
      },
      {
        Sid    = "TakeTheEip"
        Effect = "Allow"
        Action = ["ec2:AssociateAddress"]
        Resource = [
          "arn:aws:ec2:${var.aws_region}:${data.aws_caller_identity.current.account_id}:elastic-ip/${aws_eip.zabbix.allocation_id}",
          "arn:aws:ec2:${var.aws_region}:${data.aws_caller_identity.current.account_id}:instance/*",
          "arn:aws:ec2:${var.aws_region}:${data.aws_caller_identity.current.account_id}:network-interface/*",
        ]
      },
      {
        Sid      = "ListStateBucket"
        Effect   = "Allow"
        Action   = ["s3:ListBucket"]
        Resource = aws_s3_bucket.state.arn
      },
      {
        Sid      = "SyncCaddyState"
        Effect   = "Allow"
        Action   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
        Resource = "${aws_s3_bucket.state.arn}/caddy/*"
      },
      {
        Sid      = "ReportOwnHealth"
        Effect   = "Allow"
        Action   = ["autoscaling:SetInstanceHealth"]
        Resource = "*"
        Condition = {
          StringEquals = { "aws:ResourceTag/Name" = "netmon-zabbix" }
        }
      },
    ]
  })
}

resource "aws_iam_instance_profile" "zabbix_host" {
  name = "netmon-zabbix-host"
  role = aws_iam_role.zabbix_host.name
}
