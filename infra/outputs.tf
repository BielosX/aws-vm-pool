output "asg-name" {
  value = aws_autoscaling_group.asg.name
}

output "hosted-zone-id" {
  value = aws_route53_zone.local.id
}