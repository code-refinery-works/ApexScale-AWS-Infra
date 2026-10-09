terraform {
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 5.0" }
  }
}

provider "aws" { region = var.region }

data "aws_availability_zones" "az" { state = "available" }

# ── VPC ──────────────────────────────────────────────
resource "aws_vpc" "main" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_hostnames = true
  tags = { Name = "${var.prefix}-vpc" }
}

resource "aws_internet_gateway" "igw" { vpc_id = aws_vpc.main.id }

resource "aws_subnet" "public" {
  count             = 2
  vpc_id            = aws_vpc.main.id
  cidr_block        = "10.0.${count.index}.0/24"
  availability_zone = data.aws_availability_zones.az.names[count.index]
  map_public_ip_on_launch = true
  tags = { Name = "${var.prefix}-pub-${count.index}" }
}

resource "aws_subnet" "private" {
  count             = 2
  vpc_id            = aws_vpc.main.id
  cidr_block        = "10.0.${count.index + 10}.0/24"
  availability_zone = data.aws_availability_zones.az.names[count.index]
  tags = { Name = "${var.prefix}-prv-${count.index}" }
}

resource "aws_eip" "nat" { domain = "vpc" }
resource "aws_nat_gateway" "nat" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.public[0].id
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id
  route { cidr_block = "0.0.0.0/0"; gateway_id = aws_internet_gateway.igw.id }
}
resource "aws_route_table" "private" {
  vpc_id = aws_vpc.main.id
  route { cidr_block = "0.0.0.0/0"; nat_gateway_id = aws_nat_gateway.nat.id }
}
resource "aws_route_table_association" "pub" {
  count          = 2
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}
resource "aws_route_table_association" "prv" {
  count          = 2
  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private.id
}

# ── Security Groups ───────────────────────────────────
resource "aws_security_group" "alb" {
  vpc_id = aws_vpc.main.id
  name   = "${var.prefix}-alb-sg"
  ingress { from_port = 443; to_port = 443; protocol = "tcp"; cidr_blocks = ["0.0.0.0/0"] }
  ingress { from_port = 80;  to_port = 80;  protocol = "tcp"; cidr_blocks = ["0.0.0.0/0"] }
  egress  { from_port = 0;   to_port = 0;   protocol = "-1";  cidr_blocks = ["0.0.0.0/0"] }
}
resource "aws_security_group" "ecs" {
  vpc_id = aws_vpc.main.id
  name   = "${var.prefix}-ecs-sg"
  ingress { from_port = 8080; to_port = 8080; protocol = "tcp"; security_groups = [aws_security_group.alb.id] }
  egress  { from_port = 0;    to_port = 0;    protocol = "-1";  cidr_blocks = ["0.0.0.0/0"] }
}
resource "aws_security_group" "data" {
  vpc_id = aws_vpc.main.id
  name   = "${var.prefix}-data-sg"
  ingress { from_port = 5432; to_port = 5432; protocol = "tcp"; security_groups = [aws_security_group.ecs.id] }
  ingress { from_port = 6379; to_port = 6379; protocol = "tcp"; security_groups = [aws_security_group.ecs.id] }
  egress  { from_port = 0;    to_port = 0;    protocol = "-1";  cidr_blocks = ["0.0.0.0/0"] }
}

# ── ECS Fargate ───────────────────────────────────────
resource "aws_ecs_cluster" "main" { name = "${var.prefix}-cluster" }

resource "aws_iam_role" "ecs_exec" {
  name = "${var.prefix}-ecs-exec"
  assume_role_policy = jsonencode({ Version = "2012-10-17"; Statement = [{ Effect = "Allow"; Principal = { Service = "ecs-tasks.amazonaws.com" }; Action = "sts:AssumeRole" }] })
}
resource "aws_iam_role_policy_attachment" "ecs_exec" {
  role       = aws_iam_role.ecs_exec.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

resource "aws_ecs_task_definition" "app" {
  family                   = "${var.prefix}-app"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = "1024"
  memory                   = "2048"
  execution_role_arn       = aws_iam_role.ecs_exec.arn
  container_definitions = jsonencode([{
    name      = "app"
    image     = var.app_image
    portMappings = [{ containerPort = 8080 }]
    logConfiguration = {
      logDriver = "awslogs"
      options = { "awslogs-group" = "/ecs/${var.prefix}"; "awslogs-region" = var.region; "awslogs-stream-prefix" = "app" }
    }
  }])
}

resource "aws_cloudwatch_log_group" "ecs" { name = "/ecs/${var.prefix}"; retention_in_days = 7 }

resource "aws_alb" "main" {
  name            = "${var.prefix}-alb"
  subnets         = aws_subnet.public[*].id
  security_groups = [aws_security_group.alb.id]
}
resource "aws_alb_target_group" "app" {
  name        = "${var.prefix}-tg"
  port        = 8080
  protocol    = "HTTP"
  vpc_id      = aws_vpc.main.id
  target_type = "ip"
  health_check { path = "/health"; interval = 15; healthy_threshold = 2 }
}
resource "aws_alb_listener" "http" {
  load_balancer_arn = aws_alb.main.arn
  port              = 80
  protocol          = "HTTP"
  default_action { type = "redirect"; redirect { port = "443"; protocol = "HTTPS"; status_code = "HTTP_301" } }
}

resource "aws_ecs_service" "app" {
  name            = "${var.prefix}-svc"
  cluster         = aws_ecs_cluster.main.id
  task_definition = aws_ecs_task_definition.app.arn
  desired_count   = 2
  launch_type     = "FARGATE"
  network_configuration {
    subnets          = aws_subnet.private[*].id
    security_groups  = [aws_security_group.ecs.id]
  }
  load_balancer {
    target_group_arn = aws_alb_target_group.app.arn
    container_name   = "app"
    container_port   = 8080
  }
}

resource "aws_appautoscaling_target" "ecs" {
  service_namespace  = "ecs"
  resource_id        = "service/${aws_ecs_cluster.main.name}/${aws_ecs_service.app.name}"
  scalable_dimension = "ecs:service:DesiredCount"
  min_capacity       = 2
  max_capacity       = 200
}
resource "aws_appautoscaling_policy" "cpu" {
  name               = "${var.prefix}-cpu-scaling"
  policy_type        = "TargetTrackingScaling"
  resource_id        = aws_appautoscaling_target.ecs.resource_id
  scalable_dimension = aws_appautoscaling_target.ecs.scalable_dimension
  service_namespace  = aws_appautoscaling_target.ecs.service_namespace
  target_tracking_scaling_policy_configuration {
    target_value = 70.0
    predefined_metric_specification { predefined_metric_type = "ECSServiceAverageCPUUtilization" }
  }
}

# ── ElastiCache Redis Cluster ─────────────────────────
resource "aws_elasticache_subnet_group" "main" {
  name       = "${var.prefix}-cache-subnet"
  subnet_ids = aws_subnet.private[*].id
}
resource "aws_elasticache_replication_group" "redis" {
  replication_group_id       = "${var.prefix}-redis"
  description                = "Redis cluster for session/hot data"
  node_type                  = "cache.r7g.large"
  num_cache_clusters         = 2
  automatic_failover_enabled = true
  at_rest_encryption_enabled = true
  transit_encryption_enabled = true
  subnet_group_name          = aws_elasticache_subnet_group.main.name
  security_group_ids         = [aws_security_group.data.id]
}

# ── SQS ──────────────────────────────────────────────
resource "aws_sqs_queue" "main" {
  name                       = "${var.prefix}-queue"
  visibility_timeout_seconds = 300
  sqs_managed_sse_enabled    = true
}

# ── Aurora Serverless v2 + RDS Proxy ─────────────────
resource "aws_db_subnet_group" "main" {
  name       = "${var.prefix}-db-subnet"
  subnet_ids = aws_subnet.private[*].id
}
resource "aws_rds_cluster" "aurora" {
  cluster_identifier      = "${var.prefix}-aurora"
  engine                  = "aurora-postgresql"
  engine_mode             = "provisioned"
  engine_version          = "15.4"
  database_name           = "appdb"
  master_username         = "admin"
  manage_master_user_password = true
  db_subnet_group_name    = aws_db_subnet_group.main.name
  vpc_security_group_ids  = [aws_security_group.data.id]
  storage_encrypted       = true
  serverlessv2_scaling_configuration { min_capacity = 0.5; max_capacity = 128.0 }
  skip_final_snapshot     = false
  final_snapshot_identifier = "${var.prefix}-final"
}
resource "aws_rds_cluster_instance" "writer" {
  cluster_identifier = aws_rds_cluster.aurora.id
  instance_class     = "db.serverless"
  engine             = aws_rds_cluster.aurora.engine
  engine_version     = aws_rds_cluster.aurora.engine_version
  identifier         = "${var.prefix}-writer"
}
resource "aws_rds_cluster_instance" "reader" {
  count              = 2
  cluster_identifier = aws_rds_cluster.aurora.id
  instance_class     = "db.serverless"
  engine             = aws_rds_cluster.aurora.engine
  engine_version     = aws_rds_cluster.aurora.engine_version
  identifier         = "${var.prefix}-reader-${count.index}"
}

# ── CloudFront + WAF ──────────────────────────────────
resource "aws_wafv2_web_acl" "main" {
  provider    = aws
  name        = "${var.prefix}-waf"
  scope       = "CLOUDFRONT"
  default_action { allow {} }
  rule {
    name     = "AWSManagedCommon"
    priority = 1
    override_action { none {} }
    statement { managed_rule_group_statement { vendor_name = "AWS"; name = "AWSManagedRulesCommonRuleSet" } }
    visibility_config { cloudwatch_metrics_enabled = true; metric_name = "AWSCommon"; sampled_requests_enabled = true }
  }
  rule {
    name     = "RateLimit"
    priority = 2
    action { block {} }
    statement { rate_based_statement { limit = 10000; aggregate_key_type = "IP" } }
    visibility_config { cloudwatch_metrics_enabled = true; metric_name = "RateLimit"; sampled_requests_enabled = true }
  }
  visibility_config { cloudwatch_metrics_enabled = true; metric_name = "${var.prefix}WAF"; sampled_requests_enabled = true }
}

resource "aws_cloudfront_distribution" "main" {
  enabled         = true
  web_acl_id      = aws_wafv2_web_acl.main.arn
  origin {
    domain_name = aws_alb.main.dns_name
    origin_id   = "alb"
    custom_origin_config {
      http_port              = 80
      https_port             = 443
      origin_protocol_policy = "http-only"
      origin_ssl_protocols   = ["TLSv1.2"]
    }
  }
  default_cache_behavior {
    allowed_methods        = ["DELETE", "GET", "HEAD", "OPTIONS", "PATCH", "POST", "PUT"]
    cached_methods         = ["GET", "HEAD"]
    target_origin_id       = "alb"
    viewer_protocol_policy = "redirect-to-https"
    forwarded_values {
      query_string = true
      cookies { forward = "none" }
    }
    min_ttl     = 0
    default_ttl = 5
    max_ttl     = 30
  }
  restrictions { geo_restriction { restriction_type = "none" } }
  viewer_certificate { cloudfront_default_certificate = true }
}