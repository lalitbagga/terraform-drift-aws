
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
        # CloudWatch Logs permissions
        Effect = "Allow"
        Action = [
          "logs:*",
        ]
        Resource = "arn:aws:logs:${var.aws_region}:*:*"
      },
      {
        # SSM parameters
        Effect = "Allow"
        Action = [
          "ssm:GetParameter",
          "ssm:DescribeParameters",
        ]
        Resource = "arn:aws:ssm:${var.aws_region}:*:parameter/*"
      },
      {
        # IAM read permissions (for terraform plan)
        Effect = "Allow"
        Action = [
          "iam:Get*",
          "iam:List*",
          "iam:PassRole",
        ]
        Resource = "*"
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


resource "aws_sqs_queue" "drift_audit" {
  name = "terraform-drift-audit"
}

resource "aws_sns_topic_subscription" "sqs" {
  topic_arn = aws_sns_topic.drift.arn
  protocol  = "sqs"
  endpoint  = aws_sqs_queue.drift_audit.arn
}

resource "aws_sqs_queue_policy" "drift_audit" {
  queue_url = aws_sqs_queue.drift_audit.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "sns.amazonaws.com" }
      Action    = "sqs:SendMessage"
      Resource  = aws_sqs_queue.drift_audit.arn
      Condition = {
        ArnEquals = {
          "aws:SourceArn" = aws_sns_topic.drift.arn
        }
      }
    }]
  })
}

# ── Severity Classifier Lambda ─────────────────────────────────────────────────
resource "aws_iam_role" "lambda" {
  name = "terraform-drift-severity-lambda"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "lambda" {
  name = "terraform-drift-severity-lambda"
  role = aws_iam_role.lambda.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents",
        ]
        Resource = "arn:aws:logs:${var.aws_region}:*:*"
      }, {
        Effect = "Allow"
        Action = [
          "codebuild:StartBuild",
        ]
        Resource = aws_codebuild_project.remediation.arn
      }
    ]
  })
}

data "archive_file" "severity_lambda" {
  type        = "zip"
  source_file = "${path.module}/lambda/severity_classifier.py"
  output_path = "${path.module}/lambda/severity_classifier.zip"
}

resource "aws_lambda_function" "severity" {
  function_name = "terraform-drift-severity"
  filename      = data.archive_file.severity_lambda.output_path
  handler       = "severity_classifier.lambda_handler"
  runtime       = "python3.12"
  role          = aws_iam_role.lambda.arn
  timeout       = 30

  source_code_hash = data.archive_file.severity_lambda.output_base64sha256
}

resource "aws_sns_topic_subscription" "lambda" {
  topic_arn = aws_sns_topic.drift.arn
  protocol  = "lambda"
  endpoint  = aws_lambda_function.severity.arn
}

resource "aws_lambda_permission" "sns" {
  statement_id  = "AllowSNSInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.severity.function_name
  principal     = "sns.amazonaws.com"
  source_arn    = aws_sns_topic.drift.arn
}

//Auto remediation Lambda
resource "aws_iam_role" "remediation" {
  name = "terraform-drift-remediation-lambda"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "codebuild.amazonaws.com" }  
    Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "remediation" {
  name = "terraform-drift-remediation"
  role = aws_iam_role.remediation.id

    policy = jsonencode({
      Version = "2012-10-17"
      Statement = [
        {
        # Read/Write the Three-Tier Terraform state from S3
        # Needs PutObject/DeleteObject for state locking during apply
          Effect = "Allow"
          Action = [
            "s3:GetObject",
            "s3:ListBucket",
            "s3:PutObject",
            "s3:DeleteObject"
          ]
          Resource = [
            "arn:aws:s3:::three-tier-tf-state-us-east-2",
            "arn:aws:s3:::three-tier-tf-state-us-east-2/*",
          ]
        },
        {
           # CloudWatch Logs permissions
          Effect = "Allow"
          Action = [
            "logs:*",
          ]
          Resource = "arn:aws:logs:${var.aws_region}:*:*"
        },
         # SSM parameters
        {
          Effect = "Allow"
          Action = [
            "ssm:*",
          ]
          Resource = "*"
        },
        {
          # IAM permissions for creating/modifying roles and policies
          # TODO: Scope down to specific resources for production
          Effect = "Allow"
          Action = [
            "iam:*",
          ]
          Resource = "*"
        },
        {
          # EC2 permissions for VPC, instances, security groups, etc.
          Effect = "Allow"
          Action = [
            "ec2:*",
          ]
          Resource = "*"
        },
        {
          # ECR permissions for repositories
          Effect = "Allow"
          Action = [
            "ecr:*",
          ]
          Resource = "*"
        },
        {
          # ECS permissions for clusters, services, task definitions
          Effect = "Allow"
          Action = [
            "ecs:*",
          ]
          Resource = "*"
        },
        {
          # RDS permissions for database instances
          Effect = "Allow"
          Action = [
            "rds:*",
          ]
          Resource = "*"
        },
        {
          # Elastic Load Balancing permissions
          Effect = "Allow"
          Action = [
            "elasticloadbalancing:*",
          ]
          Resource = "*"
        },
        {
          # Auto Scaling permissions
          Effect = "Allow"
          Action = [
            "autoscaling:*",
          ]
          Resource = "*"
        },
        {
          # CloudWatch permissions (metrics, alarms)
          Effect = "Allow"
          Action = [
            "cloudwatch:*",
          ]
          Resource = "*"
        },
      ]
    })
}

resource "aws_codebuild_project" "remediation" {
  name          = "terraform-drift-remediation"
  description   = "Runs terraform apply to remediate LOW severity drift"
  build_timeout = 10
  service_role  = aws_iam_role.remediation.arn

  artifacts {
    type = "NO_ARTIFACTS"
  }

  environment {
    compute_type = "BUILD_GENERAL1_SMALL"
    image        = "aws/codebuild/amazonlinux2-x86_64-standard:5.0"
    type         = "LINUX_CONTAINER"
  }

  source {
    type      = "NO_SOURCE"
    buildspec = file("${path.module}/remediation-buildspec.yml")
  }

  logs_config {
    cloudwatch_logs {
      group_name = "/codebuild/terraform-drift-remediation"
    }
  }
}