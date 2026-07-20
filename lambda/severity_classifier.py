import json
import os
from datetime import datetime, timezone
import boto3

codebuild = boto3.client("codebuild")

# Severity definitions
HIGH_RISK_TYPES = {
    "aws_security_group",
    "aws_security_group_rule",
    "aws_iam_role",
    "aws_iam_policy",
    "aws_iam_role_policy",
    "aws_iam_user",
    "aws_iam_group",
    "aws_iam_access_key",
}

MEDIUM_RISK_TYPES = {
    "aws_instance",
    "aws_db_instance",
    "aws_ecs_cluster",
    "aws_ecs_service",
    "aws_ecs_task_definition",
    "aws_lb",
    "aws_lb_listener",
    "aws_lb_target_group",
    "aws_nat_gateway",
    "aws_route_table",
    "aws_network_acl",
}


def classify_change(resource_type, actions):
    """Classify a single resource change by severity."""
    if resource_type in HIGH_RISK_TYPES:
        return "HIGH"
    elif resource_type in MEDIUM_RISK_TYPES:
        # Delete or replace is more concerning than create
        if "delete" in actions or "replace" in actions:
            return "HIGH"
        return "MEDIUM"
    else:
        return "LOW"


def lambda_handler(event, context):
    """Process SNS message with drift details and classify severity."""
    print(f"Received event: {json.dumps(event)}")

    for record in event.get("Records", []):
        # SNS message is in the SNS record
        sns_message = record.get("Sns", {}).get("Message", "{}")

        try:
            drift_data = json.loads(sns_message)
        except json.JSONDecodeError:
            print(f"Failed to parse SNS message: {sns_message}")
            continue

        timestamp = drift_data.get("timestamp", datetime.now(timezone.utc).isoformat())
        project = drift_data.get("project", "unknown")
        changes = drift_data.get("changes", [])

        # Classify each change
        classified = {"HIGH": [], "MEDIUM": [], "LOW": []}

        for change in changes:
            address = change.get("address", "unknown")
            resource_type = change.get("type", "unknown")
            actions = change.get("actions", [])

            severity = classify_change(resource_type, actions)
            classified[severity].append({
                "address": address,
                "type": resource_type,
                "actions": actions,
            })

        # Build summary
        summary = {
            "timestamp": timestamp,
            "project": project,
            "total_changes": len(changes),
            "high_count": len(classified["HIGH"]),
            "medium_count": len(classified["MEDIUM"]),
            "low_count": len(classified["LOW"]),
            "classified": classified,
        }

        # Log the classified drift
        print(f"Drift classification: {json.dumps(summary, indent=2)}")

        if classified["LOW"]:
            print(f"Triggering remediation for {len(classified['LOW'])} LOW severity changes")
            codebuild.start_build(projectName=os.environ.get("REMEDIATION_PROJECT_NAME", "terraform-drift-remediation"))

        # TODO Phase 3: Auto-remediate HIGH severity changes
        # TODO Phase 3: Alert on MEDIUM severity changes

    return {"statusCode": 200, "body": "Drift classified"}
