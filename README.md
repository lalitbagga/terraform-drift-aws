# Terraform Drift Detection and Severity Pipeline on AWS

An event-driven Terraform drift pipeline built with AWS CodeBuild, SNS, SQS, and Lambda.

It runs `terraform plan -detailed-exitcode`, publishes structured resource changes, retains events for audit processing, and classifies drift as HIGH, MEDIUM, or LOW.

## Architecture

```text
CodeBuild
    ↓
terraform plan → terraform show -json
    ↓
SNS
    ├── Email notification
    ├── SQS audit queue
    └── Lambda severity classifier → CloudWatch Logs
```

## Current Status

| Phase | Scope | Status |
|---|---|---|
| Phase 1 | CodeBuild detection and SNS email | In progress — EventBridge scheduling remains |
| Phase 2 | Structured events, SQS fan-out, and Lambda classification | Completed |
| Phase 3 | Controlled remediation | Planned |
| Phase 4 | Audit history, API, and dashboards | Planned |

Automatic `terraform apply` is not implemented. Phase 3 requires approval, locking, concurrency, recovery, and audit controls before remediation can be considered safe.

## Read the Engineering Stories

The detailed architecture decisions, implementation steps, problems, fixes, and verification results are documented on:

**[blog.lalitbagga.com](https://blog.lalitbagga.com/)**

The Terraform drift series follows the project from detection through classification, safe remediation, and audit visibility.

## Repository Structure

```text
.
├── buildspec.yml
├── lambda/severity_classifier.py
├── main.tf
├── outputs.tf
├── variables.tf
└── versions.tf
```

## Quick Start

This repository currently references the author’s `Three-Tier-Infra` repository, S3 state bucket, and SSM parameter path. Update those project-specific values before deploying a fork.

Create an ignored `terraform.tfvars` file:

```hcl
aws_region = "us-east-2"
alert_email = "you@example.com"
```

Then review and deploy:

```bash
terraform init
terraform fmt -check
terraform validate
terraform plan
terraform apply
```

Until EventBridge scheduling is implemented, start CodeBuild manually:

```bash
aws codebuild start-build \
  --project-name terraform-drift \
  --region us-east-2
```

## Verify SQS Delivery

```bash
terraform output -raw sqs_queue_url

aws sqs receive-message \
  --queue-url <sqs-queue-url> \
  --max-number-of-messages 10 \
  --region us-east-2
```

## Verify Lambda Classification

```bash
aws logs tail /aws/lambda/terraform-drift-severity \
  --follow \
  --region us-east-2
```

## Security

Never commit Terraform state, tfvars, plan files, AWS credentials, SSH keys, or generated Lambda ZIP files. Review the project-specific IAM permissions and resource ARNs before deployment.

## Next

- Add and test EventBridge scheduling
- Add event IDs, schema versioning, retries, and dead-letter queues
- Design safety controls before automated remediation
