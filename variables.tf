variable "aws_region" {
  description = "AWS region"
  type        = string
  default     = "us-east-2"
}

//alert_email
variable "alert_email" {
  description = "Email address to receive drift alerts"
  type        = string
  default     = ""
}
