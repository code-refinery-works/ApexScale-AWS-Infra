output "cloudfront_domain" {
  description = "CloudFront distribution domain — primary entry point"
  value       = aws_cloudfront_distribution.main.domain_name
}

output "alb_dns" {
  description = "ALB DNS (internal, accessed via CloudFront)"
  value       = aws_alb.main.dns_name
}

output "redis_endpoint" {
  description = "ElastiCache Redis primary endpoint"
  value       = aws_elasticache_replication_group.redis.primary_endpoint_address
}

output "aurora_writer_endpoint" {
  description = "Aurora writer endpoint"
  value       = aws_rds_cluster.aurora.endpoint
}

output "aurora_reader_endpoint" {
  description = "Aurora reader endpoint"
  value       = aws_rds_cluster.aurora.reader_endpoint
}

output "sqs_queue_url" {
  description = "SQS queue URL for async write offloading"
  value       = aws_sqs_queue.main.url
}