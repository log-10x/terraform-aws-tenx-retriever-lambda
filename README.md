# terraform-aws-tenx-retriever-lambda

Terraform module that deploys the Retriever to AWS Lambda as a
4-function fan-out topology. Sibling to the EKS-based
[`terraform-aws-tenx-retriever`](https://registry.terraform.io/modules/log-10x/tenx-retriever/aws)
module; pick one based on the deployment model you want.

## What it creates

- **4 Lambda functions** from one container image (role-dispatched via the
  `ROLE` env var): `indexer`, `query`, `subquery`, `stream`.
- **3 SQS queues + 3 DLQs**: `index`, `subquery`, `stream`. Redrive
  configured; DLQs retain messages for 14 days.
- **IAM role** shared by all four Lambdas. Narrow policy: read+write+tag
  to the two S3 buckets, send to the three queues, plus CloudWatch logs.
- **S3 event notification** from the source bucket → index queue. Scoped
  by prefix/suffix via `source_prefix` / `source_suffix` to avoid
  re-triggering on engine-written index artifacts.
- **Lambda event source mappings**: SQS → each consumer Lambda.
- **Lambda Function URL** for the `query` function (optional; defaults
  to enabled with `AWS_IAM` auth).

## What it does NOT create

- **The S3 buckets.** Bring your own. The module reads the bucket names
  and attaches the notification + IAM policy. This is intentional —
  bucket ownership is typically a longer-lived concern than the
  compute layer.
- **The ECR image.** Pull the published image from `public.ecr.aws/x8r1y5t9/lambda-10x:<tag>` (see [Image](#image) below). Pass the URI via `image_uri`. To roll your own from source, build `pipeline/run-lambda/` in the engine repo and push to your own ECR.
- **Provisioned concurrency.** Add outside this module if you need
  warm-always guarantees for the query hot path.

## Usage

```hcl
module "retriever" {
  source  = "log-10x/tenx-retriever-lambda/aws"
  version = "~> 1.0"

  name_prefix        = "my-retriever"
  # Must be a private ECR URI in the same AWS account as the Lambda — see Image section below.
  image_uri          = "${data.aws_caller_identity.current.account_id}.dkr.ecr.${var.region}.amazonaws.com/lambda-10x:1.0.13"
  source_bucket_name = "my-raw-log-bucket"
  index_bucket_name  = "my-raw-log-bucket" # same as source — EKS-style layout
  tenx_api_key       = var.tenx_api_key

  source_prefix = "raw/"
  source_suffix = ".log"
}
```

## Image

The official Lambda runtime image is published to AWS ECR Public:

```
public.ecr.aws/x8r1y5t9/lambda-10x:<engine-version>
```

Tags track the engine release. `1.0.13` is current; pin to a specific tag in production. The image is built from the engine's `pipeline/run-lambda/` module and tracks the matching `log10x/quarkus-10x` Docker Hub release.

### Lambda doesn't pull from ECR Public — mirror to private ECR

AWS Lambda **only pulls container images from a private ECR repository in the same AWS account** as the function. The image must be mirrored from ECR Public to your account's ECR before the module can deploy:

```
REGION=us-east-1
ACCOUNT=$(aws sts get-caller-identity --query Account --output text)

aws ecr create-repository --repository-name lambda-10x --region $REGION

docker pull public.ecr.aws/x8r1y5t9/lambda-10x:1.0.13
docker tag  public.ecr.aws/x8r1y5t9/lambda-10x:1.0.13 \
            ${ACCOUNT}.dkr.ecr.${REGION}.amazonaws.com/lambda-10x:1.0.13

aws ecr get-login-password --region $REGION | docker login --username AWS \
  --password-stdin ${ACCOUNT}.dkr.ecr.${REGION}.amazonaws.com

docker push ${ACCOUNT}.dkr.ecr.${REGION}.amazonaws.com/lambda-10x:1.0.13
```

Then pass the private-ECR URI to `image_uri`:

```hcl
image_uri = "<account>.dkr.ecr.<region>.amazonaws.com/lambda-10x:1.0.13"
```

## ⚠ Recursion guard

When `source_bucket_name == index_bucket_name` (the single-bucket layout),
`source_prefix` must scope the notification to where raw logs land — not
to where the engine writes its index artifacts (under the `tenx/`
prefix). Without a scoped prefix, the indexer's bloom/reverse-index
writes re-trigger the S3 notification → indexer → write → loop. AWS's
Lambda recursive-invocation detector stops it, but you'll still see
unexpected invocations.

The module refuses this configuration at `terraform plan` time with:

```
Recursive-invocation risk: source_bucket_name == index_bucket_name with
empty source_prefix means indexer writes re-trigger the indexer via the
S3 notification.
```

Fixes:
- Set `source_prefix` to the directory where raw uploads land (`app/`, `raw/`, etc.)
- Or use separate buckets for `source_bucket_name` / `index_bucket_name`
- Or set `manage_s3_notification = false` and wire the notification yourself (use the queue ARN from the module output)

## Measured perf

From benchmarks against this deployment on `us-east-1`, x86_64, 6144 MB:

| Scenario           | p50     | p95     |
|--------------------|---------|---------|
| Warm query E2E     | 1.2 s   | 1.4 s   |
| Cold query E2E     | 6.7 s   | 10 s    |
| Indexer E2E        | 15.4 s  | 18.3 s  |

Warm floor is dominated by the ~300 ms SDK RTT needed for the
`_DONE.json` S3 PUT + stream-queue SQS send on query completion (correctness-
required). Cold is dominated by the pipeline's per-invocation config
parsing and template load from S3.

For sub-10 s p95 cold, pair with
[Provisioned Concurrency](https://docs.aws.amazon.com/lambda/latest/dg/provisioned-concurrency.html)
on the query and stream Lambdas. ~3-5 always-warm instances per Lambda
is enough for mid-market query volumes.

## Tunables worth knowing

| Variable | Default | Effect |
|---|---|---|
| `memory_size` | 6144 | CPU scales linearly with memory. 6144 MB measured optimal; 10240 plateaus. Lower memory is dramatically slower. |
| `pipeline_shutdown_grace_ms` | 250 | Engine's sequencer-drain wait on pipeline close. Engine default (5000) adds a flat 5 s to warm Lambda invocations because sequencer queues are already empty by close time. 250 ms safely bounds the wait; override upward only if observing dropped events on a high-throughput long-running workload. |
| `indexer_batch_size` | 1 | SQS batch size for the indexer. 1 is safest (ordered, no redelivery). Increase to trade latency for throughput under backlog. |
| `enable_query_url` | true | Lambda Function URL exposing `POST /retriever/query`. Cheaper and simpler than API Gateway. Set to false if fronting with API GW for custom auth/routing. |

## File layout

```
deploy/lambda/
  main.tf         ← resources (Lambdas, SQS, IAM, triggers)
  variables.tf    ← inputs
  outputs.tf      ← outputs
  versions.tf     ← provider constraints
  README.md       ← this file
```

## License

This repository is licensed under the [Apache License 2.0](LICENSE).

### Important: Log10x Product License Required

This repository contains infrastructure tooling for Log10x Retriever. While the Terraform module
itself is open source, **using Log10x requires a commercial license**.

| Component | License |
|-----------|---------|
| This repository (Terraform module) | Apache 2.0 (open source) |
| Log10x engine and runtime | Commercial license required |

**What this means:**
- You can freely use, modify, and distribute this Terraform module
- The Log10x software that consumes this infrastructure requires a paid subscription
- A valid Log10x API key is required to run the deployed software

**Get Started:**
- [Log10x Pricing](https://log10x.com/pricing)
- [Documentation](https://doc.log10x.com)
- [Contact Sales](mailto:sales@log10x.com)
