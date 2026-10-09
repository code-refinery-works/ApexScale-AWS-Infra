variable "region" {
  description = "AWS region"
  type        = string
  default     = "ap-northeast-1"
}

variable "prefix" {
  description = "Resource name prefix"
  type        = string
  default     = "million"
}

variable "app_image" {
  description = "ECS container image URI (e.g. 123456789.dkr.ecr.ap-northeast-1.amazonaws.com/app:latest)"
  type        = string
}