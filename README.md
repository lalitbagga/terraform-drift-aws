# Terraform Drift Detection and Severity Pipeline on AWS

An event-driven Terraform drift pipeline built with AWS CodeBuild, SNS, SQS, and Lambda.

The project runs `terraform plan -detailed-exitcode`, converts detected changes into structured JSON, sends the event through SNS, retains it in SQS for audit processing, and classifies each resource change as HIGH, MEDIUM, or LOW.

## Architecture

```text
CodeBuild
    ↓
terraform plan -detailed-exitcode
    ↓
terraform show -json
    ↓
SNS: terraform-drift-alerts
    ├── Email notification
    ├── SQS: terraform-drift-audit
    └── Lambda: terraform-drift-severity
                         ↓
                    CloudWatch Logs
```

The CodeBuild project currently needs to be started manually or by an external caller. The planned EventBridge schedule is not yet implemented in this repository.

## What It Does

### Drift detection

CodeBuild clones the target Terraform repository and runs:

```bash
terraform plan -detailed-exitcode -out=plan.tfplan -lock=false
```

Terraform returns:

- `0` — no changes
- `1` — execution error
- `2` — changes detected

The build handles exit code `2` as drift instead of treating it as a failed build.

### Structured drift event

When drift is detected, the saved plan is converted to JSON. Only the resource address, type, and actions are published:

```json
{
  "timestamp": "2026-07-14T22:00:00Z",
  "project": "Three-Tier-Infra",
  "drift_count": 2,
  "changes": [
    {
      "address": "module.compute.aws_iam_role.ec2_role",
      "type": "aws_iam_role",
      "actions": ["create"]
    }
  ]
}
```

Complete before-and-after values are intentionally excluded from the SNS message.

### SNS fan-out

SNS sends the same event to three subscribers:

- Email for a human notification
- SQS for audit ingestion
- Lambda for severity classification

The SQS queue policy only accepts messages from this project’s SNS topic.

### Severity classification

The Lambda classifier uses explicit resource-type sets:

- **HIGH** — IAM and security group resources
- **MEDIUM** — EC2, RDS, ECS, load balancers, NAT gateways, route tables, and network ACLs
- **LOW** — resource types outside the configured sets

A delete or replacement action on a MEDIUM resource is promoted to HIGH.

The complete classifier is in [`lambda/severity_classifier.py`](lambda/severity_classifier.py).

## Project Status

| Phase | Scope | Status |
|---|---|---|
| Phase 1 | CodeBuild detection and SNS email notification | In progress — EventBridge scheduling remains |
| Phase 2 | Structured SNS events, SQS fan-out, and Lambda classification | Completed |
| Phase 3 | Controlled drift remediation | Planned |
| Phase 4 | Persistent audit history, API, and dashboards | Planned |

Automatic `terraform apply` is not implemented. Remediation requires a safety design covering approvals, state locking, concurrency, stale plans, rollback, and auditability.

## Repository Structure

```text
.
├── buildspec.yml                  # CodeBuild drift detection workflow
├── lambda/
│   └── severity_classifier.py     # HIGH/MEDIUM/LOW classifier
├── main.tf                        # CodeBuild, IAM, SNS, SQS, and Lambda
├── outputs.tf                     # SQS queue URL
├── variables.tf                   # AWS region and notification email
└── versions.tf                    # Terraform and provider requirements
```

## Prerequisites

- Terraform 1.2 or newer
- AWS CLI configured with an authorized profile
- An AWS account
- An existing Terraform project and remote state to inspect
- An email address for the SNS subscription

This repository currently references the author’s `Three-Tier-Infra` project and its S3 state bucket. Forks should update the repository URL, state permissions, SSM parameter path, and other project-specific values before deploying.

## Deploy

Create a local `terraform.tfvars` file:

```hcl
aws_region = "us-east-2"
alert_email = "you@example.com"
```

The file is ignored by Git and must not be committed.

Initialize and review the plan:

```bash
terraform init
terraform fmt -check
terraform validate
terraform plan
```

Apply only after reviewing the proposed resources and IAM permissions:

```bash
terraform apply
```

Confirm the SNS email subscription before expecting email alerts.

## Start a Detection Run

Until EventBridge scheduling is added, start the CodeBuild project manually:

```bash
aws codebuild start-build \
  --project-name terraform-drift \
  --region us-east-2
```

Use the returned build ID to inspect the run:

```bash
aws codebuild batch-get-builds \
  --ids <build-id> \
  --region us-east-2
```

## Verify SQS Delivery

Retrieve the queue URL from Terraform:

```bash
terraform output -raw sqs_queue_url
```

Then read up to 10 messages:

```bash
aws sqs receive-message \
  --queue-url <sqs-queue-url> \
  --max-number-of-messages 10 \
  --region us-east-2
```

Always specify the correct region. Querying a queue URL through the wrong regional endpoint can return `NonExistentQueue` even when the queue exists.

## Verify Lambda Classification

Tail the classifier’s CloudWatch log group:

```bash
aws logs tail /aws/lambda/terraform-drift-severity \
  --follow \
  --region us-east-2
```

A successful invocation writes the total number of changes, counts for each severity, and the classified resource details.

## Security Notes

- Never commit `.tfstate`, `.tfvars`, plan files, credentials, SSH keys, or generated Lambda ZIP files.
- Review the project-specific S3 and SSM ARNs in `main.tf` before deployment.
- Keep complete Terraform before-and-after values out of notifications and logs unless they have been reviewed for sensitive data.
- Treat severity as an initial policy signal, not proof that a change is safe to remediate.
- Use a dedicated AWS account or sandbox while adapting the project.

## Next Steps

- Add and test EventBridge scheduling
- Add an event schema version and unique event ID
- Add dead-letter queues and retry handling
- Make consumers idempotent under duplicate SNS delivery
- Design approval and safety controls before any automated remediation
