############################################################
# Retriever — AWS Lambda deployment
############################################################
# Creates the full Lambda-based retriever stack:
#   - 4 Lambda functions (indexer, query, subquery, stream) from one image
#   - 3 SQS queues + DLQs (index, subquery, stream)
#   - IAM role + inline policy
#   - S3 event notification wiring (source bucket → index queue)
#   - CloudWatch log groups (implicit via Lambda)
#
# The source and index S3 buckets are BYO: caller either creates them
# before calling this module (recommended for production) or supplies
# names of buckets to create. See examples/ for both patterns.
############################################################

locals {
  name_prefix = var.name_prefix
  common_tags = merge(
    {
      "tenx-retriever-deploy"  = "lambda"
      "tenx-retriever-runtime" = var.runtime_flavor
      terraform-module         = "tenx-retriever-lambda"
      terraform-module-version = "v1.1.0"
      managed-by               = "tenx-terraform"
    },
    var.tags,
  )
}

############################################################
# SQS queues (index + subquery + stream; each with DLQ)
############################################################

resource "aws_sqs_queue" "dlq" {
  for_each = toset(["index", "subquery", "stream"])

  name                      = "${local.name_prefix}-${each.key}-queue-dlq"
  message_retention_seconds = 1209600 # 14 days — max
  tags                      = local.common_tags
}

resource "aws_sqs_queue" "main" {
  for_each = toset(["index", "subquery", "stream"])

  name                       = "${local.name_prefix}-${each.key}-queue"
  visibility_timeout_seconds = var.visibility_timeout_seconds
  message_retention_seconds  = var.message_retention_seconds
  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.dlq[each.key].arn
    maxReceiveCount     = var.max_receive_count
  })
  tags = local.common_tags
}

# Let S3 send events into the index queue
resource "aws_sqs_queue_policy" "index_s3" {
  queue_url = aws_sqs_queue.main["index"].url
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "s3.amazonaws.com" }
      Action    = "sqs:SendMessage"
      Resource  = aws_sqs_queue.main["index"].arn
      Condition = {
        ArnLike = {
          "aws:SourceArn" = "arn:aws:s3:::${var.source_bucket_name}"
        }
      }
    }]
  })
}

############################################################
# IAM role shared by all 4 Lambdas
############################################################

data "aws_iam_policy_document" "lambda_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "lambda" {
  name               = "${local.name_prefix}-lambda"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume.json
  tags               = local.common_tags
}

resource "aws_iam_role_policy_attachment" "lambda_basic" {
  role       = aws_iam_role.lambda.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy_attachment" "lambda_sqs" {
  role       = aws_iam_role.lambda.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaSQSQueueExecutionRole"
}

resource "aws_iam_role_policy" "lambda_s3" {
  # The engine's async S3 writes include tagged PUTs (bloom-filter debug values).
  # s3:PutObjectTagging is required or tagged writes silently fail with 400.
  role = aws_iam_role.lambda.name
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:PutObject",
          "s3:PutObjectTagging",
          "s3:DeleteObject",
          "s3:ListBucket",
        ]
        Resource = [
          "arn:aws:s3:::${var.source_bucket_name}",
          "arn:aws:s3:::${var.source_bucket_name}/*",
          "arn:aws:s3:::${var.index_bucket_name}",
          "arn:aws:s3:::${var.index_bucket_name}/*",
        ]
      },
      {
        Effect   = "Allow"
        Action   = ["sqs:SendMessage", "sqs:GetQueueAttributes"]
        Resource = "arn:aws:sqs:*:*:${local.name_prefix}-*"
      },
    ]
  })
}

############################################################
# Lambda functions (4 roles from one container image)
############################################################

locals {
  # Engine `indexContainer` option, formatted as "<bucket>" or
  # "<bucket>/<path>". The engine parses out the path and prepends it to
  # every index artifact key it writes.
  index_path_normalized = (
    var.index_bucket_path == "" ? "" :
    endswith(var.index_bucket_path, "/") ? trimsuffix(var.index_bucket_path, "/") :
    var.index_bucket_path
  )
  index_container = (
    local.index_path_normalized == ""
    ? var.index_bucket_name
    : "${var.index_bucket_name}/${local.index_path_normalized}"
  )

  # Shared env for all Lambdas. Role-specific overrides merged in per-function.
  #
  # JAVA_TOOL_OPTIONS is set for BOTH runtime flavors and must stay that way.
  # On the JVM flavor the launcher applies it. On the native flavor there is no
  # launcher, so RetrieverBootstrap parses this variable itself in a static
  # initialiser and calls System.setProperty for each -D. Dropping it because
  # "a native image has no JVM" breaks the subquery role on every index range
  # with `IllegalArgumentException: restricted header name: "host"` — the JDK
  # HttpClient refuses a caller-supplied Host header unless the property allows
  # it. One variable, two mechanisms, same value.
  common_env = merge(
    {
      TENX_HOME                            = "/var/task/tenx-home"
      TENX_LOG_APPENDER                    = "tenxConsoleAppender"
      TENX_LOG_PATH                        = "/tmp/"
      JAVA_TOOL_OPTIONS                    = "-Djdk.httpclient.allowRestrictedHeaders=host"
      TENX_STREAMER_INPUT_BUCKET           = var.source_bucket_name
      TENX_STREAMER_INDEX_BUCKET           = local.index_container
      TENX_INVOKE_PIPELINE_SCAN_ENDPOINT   = aws_sqs_queue.main["subquery"].url
      TENX_INVOKE_PIPELINE_STREAM_ENDPOINT = aws_sqs_queue.main["stream"].url
      TENX_QUARKUS_SUBQUERY_QUEUE_URL      = aws_sqs_queue.main["subquery"].url
      TENX_QUARKUS_QUERY_QUEUE_URL         = aws_sqs_queue.main["subquery"].url
      TENX_STREAM_PARALLEL_OBJECTS         = "20"
      TENX_PIPELINE_SHUTDOWN_GRACE_MS      = tostring(var.pipeline_shutdown_grace_ms)
    },
    var.tenx_api_key == "" ? {} : { TENX_API_KEY = var.tenx_api_key },
    var.extra_env,
  )

  roles = {
    indexer = {
      description = "Retriever indexer — S3 event → byte-range + bloom + reverse index"
      extra_env   = { ROLE = "indexer", INDEX_WRITE_BUCKET = local.index_container }
    }
    query = {
      description = "Retriever query-submit — HTTP → pipeline launch → SQS fan-out"
      extra_env = {
        ROLE                     = "query"
        QUERY_READ_BUCKET        = var.source_bucket_name
        QUERY_INDEX_BUCKET       = local.index_container
        QUERY_SUBQUERY_QUEUE_URL = aws_sqs_queue.main["subquery"].url
        QUERY_STREAM_QUEUE_URL   = aws_sqs_queue.main["stream"].url
      }
    }
    subquery = {
      description = "Retriever sub-query scan — one time-slice → stream requests"
      extra_env   = { ROLE = "subquery" }
    }
    stream = {
      description = "Retriever stream worker — fetch + decode + match + byte-count marker"
      extra_env   = { ROLE = "stream" }
    }
  }
}

# Both runtime flavors are PackageType=Image, so the Lambda resource itself is
# almost flavor-agnostic: the java21-vs-provided.al2023 base, the handler-vs-
# bootstrap dispatch and the CMD all live inside the image. `runtime` and
# `handler` are unset for either flavor and must stay unset — setting them is
# what CreateFunction rejects on an Image package.
#
# What is NOT flavor-agnostic is the architecture. The JVM image is a multi-arch
# manifest, so Lambda picks the matching variant and x86_64 was safe to hardcode.
# A native image is a single compiled binary: an amd64 `bootstrap` on an arm64
# function fails at first invocation with an exec-format error, not at plan or
# apply time. Hence architectures is now a variable the caller must line up with
# the image it built.
resource "aws_lambda_function" "role" {
  for_each = local.roles

  function_name = "${local.name_prefix}-${each.key}"
  description   = each.value.description
  role          = aws_iam_role.lambda.arn
  package_type  = "Image"
  image_uri     = var.image_uri
  architectures = var.architectures
  memory_size   = var.memory_size
  timeout       = var.timeout_seconds

  # Only emitted when the caller overrides the image's own ENTRYPOINT/CMD.
  # The stock images already carry the right one (the handler string for the
  # JVM flavor, an ignored argv token for native), so this stays absent by
  # default rather than pinning a value that belongs to the image.
  dynamic "image_config" {
    for_each = (
      length(var.image_entry_point) > 0 || length(var.image_command) > 0
      ? [1] : []
    )
    content {
      entry_point = length(var.image_entry_point) > 0 ? var.image_entry_point : null
      command     = length(var.image_command) > 0 ? var.image_command : null
    }
  }

  # The stream role fetches blobs and decodes them through /tmp, which is also
  # TENX_LOG_PATH. 512 MB is the Lambda default and the module's default; raise
  # it when object sizes grow rather than discovering the limit as a mid-fetch
  # "No space left on device".
  dynamic "ephemeral_storage" {
    for_each = var.ephemeral_storage_mb == null ? [] : [var.ephemeral_storage_mb]
    content {
      size = ephemeral_storage.value
    }
  }

  environment {
    variables = merge(local.common_env, each.value.extra_env)
  }

  tags = merge(local.common_tags, { "tenx-retriever-role" = each.key })
}

############################################################
# Triggers — S3 event → index queue; SQS → consumer Lambdas
############################################################

resource "aws_s3_bucket_notification" "source_to_index" {
  count = var.manage_s3_notification ? 1 : 0

  bucket = var.source_bucket_name

  queue {
    id            = "tenx-retriever-index-on-put"
    queue_arn     = aws_sqs_queue.main["index"].arn
    events        = ["s3:ObjectCreated:*"]
    filter_prefix = var.source_prefix
    filter_suffix = var.source_suffix
  }

  depends_on = [aws_sqs_queue_policy.index_s3]

  lifecycle {
    # When source and index share a bucket, index_bucket_path must be
    # non-empty so engine writes land under a key prefix that does not
    # overlap with the S3 -> SQS notification scope. Different buckets, or
    # an externally-managed notification (manage_s3_notification=false),
    # also satisfy this constraint.
    precondition {
      condition     = var.source_bucket_name != var.index_bucket_name || var.index_bucket_path != ""
      error_message = "source_bucket_name == index_bucket_name requires a non-empty index_bucket_path (e.g. \"indexing-results/\") to keep engine writes outside the source notification scope. Alternatives: use different buckets, or set manage_s3_notification=false."
    }
  }
}

resource "aws_lambda_event_source_mapping" "index" {
  event_source_arn = aws_sqs_queue.main["index"].arn
  function_name    = aws_lambda_function.role["indexer"].arn
  batch_size       = var.indexer_batch_size
}

resource "aws_lambda_event_source_mapping" "subquery" {
  event_source_arn = aws_sqs_queue.main["subquery"].arn
  function_name    = aws_lambda_function.role["subquery"].arn
  batch_size       = 1
}

resource "aws_lambda_event_source_mapping" "stream" {
  event_source_arn = aws_sqs_queue.main["stream"].arn
  function_name    = aws_lambda_function.role["stream"].arn
  batch_size       = 1
}

############################################################
# HTTP entry for the query Lambda (Function URL — simpler than API GW)
############################################################

resource "aws_lambda_function_url" "query" {
  count              = var.enable_query_url ? 1 : 0
  function_name      = aws_lambda_function.role["query"].function_name
  authorization_type = var.query_url_auth
}
