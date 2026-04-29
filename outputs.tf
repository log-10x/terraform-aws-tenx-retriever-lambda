output "lambda_function_names" {
  description = "Map of role name → Lambda function name for the four retriever roles."
  value       = { for k, f in aws_lambda_function.role : k => f.function_name }
}

output "lambda_function_arns" {
  description = "Map of role name → Lambda function ARN."
  value       = { for k, f in aws_lambda_function.role : k => f.arn }
}

output "queue_urls" {
  description = "Map of SQS queue name (index, subquery, stream) → URL."
  value       = { for k, q in aws_sqs_queue.main : k => q.url }
}

output "queue_arns" {
  description = "Map of SQS queue name → ARN."
  value       = { for k, q in aws_sqs_queue.main : k => q.arn }
}

output "dlq_urls" {
  description = "Map of SQS DLQ name → URL."
  value       = { for k, q in aws_sqs_queue.dlq : k => q.url }
}

output "iam_role_arn" {
  description = "ARN of the IAM role shared by all four Lambdas."
  value       = aws_iam_role.lambda.arn
}

output "query_function_url" {
  description = "HTTP endpoint for the query Lambda (if enable_query_url is true). Signed with SigV4 when auth is AWS_IAM."
  value       = var.enable_query_url ? aws_lambda_function_url.query[0].function_url : null
}
