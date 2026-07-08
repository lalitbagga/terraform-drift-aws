
# IAM Role for CodeBuild
resource "aws_iam_role" "codebuild" {
  name = "terraform-drift-codebuild"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "codebuild.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "codebuild" {
  name = "terraform-drift-codebuild"
  role = aws_iam_role.codebuild.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        # Read the Three-Tier Terraform state from S3
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:ListBucket",
        ]
        Resource = [
          "arn:aws:s3:::three-tier-tf-state-us-east-2",
          "arn:aws:s3:::three-tier-tf-state-us-east-2/*",
        ]
      },
      {
        # Write build logs to CloudWatch
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents",
        ]
        Resource = "arn:aws:logs:${var.aws_region}:*:*"
      },
      {
        # Read SSM parameters (for SSH keys, etc.)
        Effect = "Allow"
        Action = [
          "ssm:GetParameter",
        ]
        Resource = "arn:aws:ssm:${var.aws_region}:*:parameter/threeTier/*"
      },
    {
        # Publish drift alerts to SNS
        Effect = "Allow"
        Action = [
          "sns:Publish",
        ]
        Resource = aws_sns_topic.drift.arn
      },
    ]
  })
}

# CodeBuild Project 
resource "aws_codebuild_project" "drift" {
  name          = "terraform-drift"
  description   = "Runs terraform plan against Three-Tier-Infra to detect drift"
  build_timeout = 10
  service_role  = aws_iam_role.codebuild.arn

  artifacts {
    type = "NO_ARTIFACTS"
  }

  environment {
    compute_type = "BUILD_GENERAL1_SMALL"
    image        = "aws/codebuild/amazonlinux2-x86_64-standard:5.0"
    type         = "LINUX_CONTAINER"

    environment_variable {         
        name  = "SNS_TOPIC_ARN"
        value = aws_sns_topic.drift.arn
    }
  }

 

  source {
    type      = "NO_SOURCE"
    buildspec = file("${path.module}/buildspec.yml")
  }

  logs_config {
    cloudwatch_logs {
      group_name = "/codebuild/terraform-drift"
    }
  }
}

#SNS topic 
resource "aws_sns_topic" "drift" {
  name = "terraform-drift-alerts"
}

resource "aws_sns_topic_subscription" "drift" {
  topic_arn = aws_sns_topic.drift.arn
  protocol  = "email"
  endpoint  = var.alert_email
}


