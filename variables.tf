variable "name_prefix" {
  description = "Prefix for all created resources (Lambdas, SQS queues, IAM role)."
  type        = string
}

variable "image_uri" {
  description = "Full ECR image URI for the retriever Lambda container (e.g. 123.dkr.ecr.us-east-1.amazonaws.com/tenx-retriever-lambda:1.0.0)."
  type        = string
}

variable "runtime_flavor" {
  description = <<-EOT
    Which retriever image `image_uri` points at.

      jvm     lambda-10x:<version>          — shadow jar on the managed
              public.ecr.aws/lambda/java:21 base, handler-dispatched
              (com.log10x.ext.lambda.RetrieverHandler::handleRequest).
              Multi-arch manifest, so either architecture resolves.

      native  lambda-10x:<version>-native   — GraalVM binary named `bootstrap`
              on public.ecr.aws/lambda/provided:al2023, driving the Lambda
              Runtime API itself (RetrieverBootstrap). Single architecture per
              tag; `architectures` must match the one it was compiled for.

    Both are PackageType=Image, so this value changes tagging and the
    architecture default only. Membership is checked here; agreement with the
    image `image_uri` actually points at is checked at plan time by
    terraform_data.flavor_gate in main.tf, because a variable validation may
    only reference its own variable.
  EOT
  type        = string
  default     = "jvm"
  validation {
    condition     = contains(["jvm", "native"], var.runtime_flavor)
    error_message = "runtime_flavor must be \"jvm\" or \"native\"."
  }
}

variable "allow_flavor_tag_mismatch" {
  description = <<-EOT
    Escape hatch for terraform_data.flavor_gate. The gate reads the flavor off
    the image_uri tag suffix, which is the convention the published images
    follow (`<version>-native` for native, `<version>` for jvm). Set true when
    that convention does not apply to your reference — a digest-pinned URI, or
    a retag into your own registry under different naming — and you accept that
    runtime_flavor is then unverified. Leave false everywhere else: it is the
    only thing standing between a wrong runtime_flavor and a stack that plans
    clean, applies clean, and fails at first invocation.
  EOT
  type        = bool
  default     = false
}

variable "architectures" {
  description = <<-EOT
    Instruction set for all four functions. Exactly one entry — Lambda accepts a
    list but rejects more than one.

    For runtime_flavor = "native" this must match the architecture the binary was
    compiled for. A mismatch is not caught at plan or apply: CreateFunction
    succeeds and the first invocation fails with an exec-format error.
  EOT
  type        = list(string)
  default     = ["x86_64"]
  validation {
    condition = (
      length(var.architectures) == 1 &&
      contains(["x86_64", "arm64"], var.architectures[0])
    )
    error_message = "architectures must be exactly one of [\"x86_64\"] or [\"arm64\"]."
  }
}

variable "image_entry_point" {
  description = "Override the image's ENTRYPOINT. Leave empty to use the image's own — which is what both published flavors expect."
  type        = list(string)
  default     = []
}

variable "image_command" {
  description = "Override the image's CMD. Leave empty to use the image's own: the handler string for the JVM flavor, an argv token the native bootstrap ignores."
  type        = list(string)
  default     = []
}

variable "ephemeral_storage_mb" {
  description = "Size of /tmp in MB (512-10240). Null leaves the Lambda default of 512. Raise it when the stream role handles large blobs."
  type        = number
  default     = null
  validation {
    condition     = var.ephemeral_storage_mb == null || try(var.ephemeral_storage_mb >= 512 && var.ephemeral_storage_mb <= 10240, false)
    error_message = "ephemeral_storage_mb must be between 512 and 10240, or null."
  }
}

variable "source_bucket_name" {
  description = "Name of the S3 bucket where raw log objects land. Indexer reads from here. Must already exist."
  type        = string
}

variable "index_bucket_name" {
  description = "Name of the S3 bucket where index artifacts are written. Can be the same as source_bucket_name for the EKS-style single-bucket layout."
  type        = string
}

variable "index_bucket_path" {
  description = <<-EOT
    Path prefix within index_bucket_name under which the engine writes all
    index artifacts (byte-range, reverse-index, bloom filters, templates,
    query results). Trailing slash is optional. Required when
    source_bucket_name equals index_bucket_name.
  EOT
  type        = string
  default     = "indexing-results/"
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
