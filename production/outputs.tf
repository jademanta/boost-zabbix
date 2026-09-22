output "zabbix_elastic_ip" {
  description = "Static public IP. Point netmon.boocorp.com (Cloudflare, proxied) here. Re-attached automatically by every replacement instance."
  value       = aws_eip.zabbix.public_ip
}

output "poller_cidrs" {
  description = "Subnets the Zabbix host can appear in. Target-side rules (agents' Server=, SNMP ACLs, security groups) should allow these instead of a single IP."
  value       = [for s in data.aws_subnet.asg : s.cidr_block]
}

output "db_endpoint" {
  value = aws_db_instance.zabbix.address
}

output "db_secret_arn" {
  description = "Secrets Manager secret holding the RDS master password (username zabbix)."
  value       = aws_db_instance.zabbix.master_user_secret[0].secret_arn
}

output "caddy_state_path" {
  description = "Where Caddy's certificate dir lives between rebuilds."
  value       = "s3://${aws_s3_bucket.state.bucket}/${local.state_prefix}/"
}

output "asg_name" {
  value = aws_autoscaling_group.zabbix.name
}

output "url" {
  value = "https://${var.fqdn}/"
}

output "current_instance_id_command" {
  description = "The instance id changes on every self-heal; look it up from the ASG."
  value       = "aws --profile boostprod autoscaling describe-auto-scaling-groups --auto-scaling-group-names ${aws_autoscaling_group.zabbix.name} --query 'AutoScalingGroups[0].Instances[0].InstanceId' --output text"
}

output "ssm_session_command" {
  value = "aws --profile boostprod ssm start-session --target $(aws --profile boostprod autoscaling describe-auto-scaling-groups --auto-scaling-group-names ${aws_autoscaling_group.zabbix.name} --query 'AutoScalingGroups[0].Instances[0].InstanceId' --output text)"
}

output "self_heal_test_command" {
  description = "Terminate the running host; the ASG replaces it and the new one re-takes the EIP and reconnects to RDS. Expect ~5 minutes of monitoring gap."
  value       = "aws --profile boostprod autoscaling terminate-instance-in-auto-scaling-group --no-should-decrement-desired-capacity --instance-id $(aws --profile boostprod autoscaling describe-auto-scaling-groups --auto-scaling-group-names ${aws_autoscaling_group.zabbix.name} --query 'AutoScalingGroups[0].Instances[0].InstanceId' --output text)"
}
