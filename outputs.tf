output "sqs_queue_url" {
  description = "URL of the drift audit SQS queue"
  value       = aws_sqs_queue.drift_audit.url
}
