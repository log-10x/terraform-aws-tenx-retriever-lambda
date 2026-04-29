variable "name_prefix" {
  description = "Prefix for all created resources (Lambdas, SQS queues, IAM role)."
  type        = string
}

variable "image_uri" {
  description = "Full ECR image URI for the retriever Lambda container (e.g. 123.dkr.ecr.us-east-1.amazonaws.com/tenx-retriever-lambda:1.0.0)."
  type        = string
}

variable "source_bucket_name" {
  description = "Name of the S3 bucket where raw log objects land. Indexer reads from here. Must already exist."
  type        = string
}

variable "index_bucket_name" {
  description = "Name of the S3 bucket where index artifacts are written. Can be the same as source_bucket_name for the EKS-style single-bucket layout."
  type        = string
}

variable "source_prefix" {
  description = "Optional S3 key prefix filter for the source bucket's ObjectCreated notifications. Scope to the directory that holds raw log uploads to avoid re-triggering on engine-written index files."
  type        = string
  default     = ""
}

variable "source_suffix" {
  description = "Optional S3 key suffix filter for source bucket notifications (e.g. '.log')."
  type        = string
  default     = ""
}

variable "tenx_api_key" {
  description = "Log10x API key. Passed as TENX_API_KEY env var. Get yours at https://console.log10x.com. Leave blank if already wired via a Lambda environment variable."
  type        = string
  default     = ""
  sensitive   = true
}

variable "memory_size" {
  description = "Lambda memory (MB). 6144 measured optimal for retriever workloads — see deploy-lambda.md for the perf curve."
  type        = number
  default     = 6144
}

variable "timeout_seconds" {
  description = "Lambda function timeout in seconds."
  type        = number
  default     = 300
}

variable "visibility_timeout_seconds" {
  description = "SQS visibility timeout for main queues. Should be >= Lambda timeout."
  type        = number
  default     = 300
}

variable "message_retention_seconds" {
  description = "SQS message retention for main queues."
  type        = number
  default     = 345600 # 4 days
}

variable "max_receive_count" {
  description = "Number of SQS receives before a message is sent to its DLQ."
  type        = number
  default     = 3
}

variable "indexer_batch_size" {
  description = "SQS batch size for the indexer Lambda. 1 is safest; higher trades latency for throughput if backlog builds."
  type        = number
  default     = 1
}

variable "pipeline_shutdown_grace_ms" {
  description = "Max wait for the pipeline's sequencer queues to drain on close. Default 5000 matches the engine default (EKS long-running). Lambda workloads benefit from 250 to avoid a flat 5s tax on warm invocations."
  type        = number
  default     = 250
}

variable "manage_s3_notification" {
  description = "If true, this module manages the source bucket's notification configuration. Set false if the bucket's notifications are managed elsewhere."
  type        = bool
  default     = true
}

variable "enable_query_url" {
  description = "If true, create a Lambda Function URL for the query Lambda. Otherwise the query Lambda is invoke-only."
  type        = bool
  default     = true
}

variable "query_url_auth" {
  description = "Auth mode for the query Function URL. 'AWS_IAM' (signed requests only) or 'NONE' (public — only acceptable for demo)."
  type        = string
  default     = "AWS_IAM"
  validation {
    condition     = contains(["AWS_IAM", "NONE"], var.query_url_auth)
    error_message = "query_url_auth must be AWS_IAM or NONE."
  }
}

variable "extra_env" {
  description = "Extra environment variables to merge into all Lambda functions. Role-specific variables can be added via the module's internal merge order."
  type        = map(string)
  default     = {}
}

variable "tags" {
  description = "Additional tags applied to all resources."
  type        = map(string)
  default     = {}
}
