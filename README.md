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
- **The ECR image.** Pull the published image from `docker.io/log10x/lambda-10x:<tag>` or `ghcr.io/log-10x/lambda-10x:<tag>`, mirror it into your account's private ECR, and pass that URI via `image_uri` (see [Image](#image) below). To roll your own from source, build `pipeline/run-lambda/` in the engine repo and push to your own ECR.
- **Provisioned concurrency.** Add outside this module if you need
  warm-always guarantees for the query hot path.

## Usage

```hcl
module "retriever" {
  source  = "log-10x/tenx-retriever-lambda/aws"
  version = "~> 3.0"

  name_prefix = "my-retriever"
  # Must be a private ECR URI in the same AWS account as the Lambda — see Image section below.
  # lambda_packaging defaults to "native", so the tag carries the -native suffix
  # and architectures stays at its ["x86_64"] default. Nothing else to set.
  image_uri          = "${data.aws_caller_identity.current.account_id}.dkr.ecr.${var.region}.amazonaws.com/lambda-10x:1.1.38-native"
  source_bucket_name = "my-raw-log-bucket"
  index_bucket_name  = "my-raw-log-bucket" # same as source — EKS-style layout
  index_bucket_path  = "indexing-results/" # required when source==index bucket; see Recursion guard
  tenx_api_key       = var.tenx_api_key

  source_prefix = "raw/"
  source_suffix = ".log"
}
```

## Image

The Lambda images are published to Docker Hub and GHCR:

```
docker.io/log10x/lambda-10x:<engine-version>-native   ← default packaging
ghcr.io/log-10x/lambda-10x:<engine-version>-native
```

Tags track the engine release; `1.1.38` is current. Pin a tag — never rely on
`:latest`, which the module rejects at plan time anyway.

> The ECR Public mirror at `public.ecr.aws/x8r1y5t9/lambda-10x` is **stale**: its
> newest tag is `1.0.13` and it carries no `-native` tag at all. Pull from Docker
> Hub or GHCR. (Verified 2026-08-02 against the ECR Public gallery API, which
> lists only `0.21.0*`, `1.0.13`, `latest*`.)

### Two Lambda packagings

Two images are published per engine release. Both are `PackageType=Image`, so the module deploys either one through the same `image_uri`; the difference lives entirely inside the image.

| | `<version>-native` (**default**) | `<version>` (jvm) |
|---|---|---|
| Base | `public.ecr.aws/lambda/provided:al2023` | `public.ecr.aws/lambda/java:21` |
| Payload | a compiled binary named `bootstrap` | `run-lambda-<version>-all.jar` |
| Dispatch | `RetrieverBootstrap` drives the Runtime API itself | managed runtime calls `RetrieverHandler::handleRequest` |
| Architectures | `x86_64` only — single-arch tag, built `linux/amd64` | multi-arch manifest, either value resolves |
| Cold start | sub-second | seconds |

`lambda_packaging` defaults to `"native"` and `architectures` defaults to
`["x86_64"]`, which is the pairing the published native tag requires. A call
site that wants the default packaging sets neither:

```hcl
image_uri = "<acct>.dkr.ecr.us-east-1.amazonaws.com/lambda-10x:1.1.38-native"
```

Deploying the JVM packaging is now the explicit case — and the only way to run
the retriever on `arm64`, since the published native tag is amd64-only:

```hcl
lambda_packaging = "jvm"
architectures    = ["arm64"]                                                # or ["x86_64"]
image_uri        = "<acct>.dkr.ecr.us-east-1.amazonaws.com/lambda-10x:1.1.38"
```

`lambda_packaging` and `image_uri` are cross-checked at plan time by
`terraform_data.packaging_gate`. Declaring one packaging while pointing at the
other used to plan clean, apply clean, and fail at first invocation, leaving a
tag that said the opposite of the truth. Now it stops at `terraform plan`:

```
Error: Resource precondition failed
  lambda_packaging = "native" contradicts the image_uri tag "1.1.32".
```

The check reads the packaging off the tag suffix, which is the convention the
published images follow — `<version>-native` for native, `<version>` for jvm. A
tagless `image_uri` and a digest-pinned one both fail too, the first because
`:latest` is a different image on every deploy, the second because a digest
names no packaging. If you retag into your own registry under a different
convention, set `allow_packaging_tag_mismatch = true` and accept that
`lambda_packaging` is then unverified.

This is a plan-time precondition rather than a variable `validation` block
because Terraform only lets a variable validation reference its own variable.
`terraform validate` still passes on a mismatch; `terraform plan` is the
earliest point where the two values can be compared.

The same gate refuses `architectures = ["arm64"]` under
`lambda_packaging = "native"`, which is the other pairing that used to reach
production before failing:

```
Error: Resource precondition failed
  architectures = ["arm64"] with lambda_packaging = "native" cannot run.
  Set lambda_packaging = "jvm" to deploy arm64: [...]
```

That check does not read the image, because a tag names the packaging and says
nothing about the architecture. It reads the two inputs against each other and
relies on how the images are published: `docker manifest inspect
log10x/lambda-10x:1.1.39-native` returns one image manifest at
`linux/amd64`, while `log10x/lambda-10x:1.1.39` returns an index carrying
`linux/arm64` and `linux/amd64`. `CreateFunction` accepts `["arm64"]` against
an amd64 `bootstrap`, `terraform apply` reports success, and the first
invocation fails with an exec-format error.

Two ways to run on `arm64`: set `lambda_packaging = "jvm"` and point `image_uri`
at the untagged-suffix image, or compile the native image for arm64 yourself,
point `image_uri` at that build, and set `allow_arm64_native = true`. Staying on
`x86_64` needs nothing — it is the default.

`JAVA_TOOL_OPTIONS` is set on both packagings and should stay that way. The native binary has no JVM launcher to read it, so `RetrieverBootstrap` parses the variable itself and applies each `-D` before the HTTP client initialises. Removing it as JVM-only leftovers breaks the subquery role on every index range with `restricted header name: "host"`.

### Why "packaging" and not "flavor"

`jvm` and `native` say how the retriever is built into a Lambda container
image. They do not name an engine distribution. Log10x ships two distributions
— the compiler (container/JVM) and the runtime (a native binary) — and the
retriever is neither: it is an application, the same class of thing as the
reporter or the receiver, and it runs on Lambda regardless of which
distribution produced its jar or binary. Under the old name,
`runtime_flavor = "jvm"` read as "the runtime distribution, in its JVM
variant", which is not a thing that exists.

The rename lands in v2.0.0 because Terraform has no variable aliasing: there is
no deprecation window in which both names work. See
[Upgrading from v1.x](#upgrading-from-v1x).

### Lambda doesn't pull from ECR Public — mirror to private ECR

AWS Lambda **only pulls container images from a private ECR repository in the same AWS account** as the function. The image must be mirrored from ECR Public to your account's ECR before the module can deploy:

```
REGION=us-east-1
ACCOUNT=$(aws sts get-caller-identity --query Account --output text)
TAG=1.1.38-native

aws ecr create-repository --repository-name lambda-10x --region $REGION

# --platform linux/amd64 matters on an arm64 workstation: the native tag has no
# arm64 variant to fall back to, and a silent emulated pull would push an image
# Lambda cannot run.
docker pull --platform linux/amd64 docker.io/log10x/lambda-10x:${TAG}
docker tag  docker.io/log10x/lambda-10x:${TAG} \
            ${ACCOUNT}.dkr.ecr.${REGION}.amazonaws.com/lambda-10x:${TAG}

aws ecr get-login-password --region $REGION | docker login --username AWS \
  --password-stdin ${ACCOUNT}.dkr.ecr.${REGION}.amazonaws.com

docker push ${ACCOUNT}.dkr.ecr.${REGION}.amazonaws.com/lambda-10x:${TAG}
```

Then pass the private-ECR URI to `image_uri`:

```hcl
image_uri = "<account>.dkr.ecr.<region>.amazonaws.com/lambda-10x:1.1.38-native"
```

## Upgrading from v2.x

v3.0.0 changes one default and nothing else:

| | v2.0.0 | v3.0.0 |
|---|---|---|
| `lambda_packaging` default | `"jvm"` | `"native"` |
| `architectures` default | `["x86_64"]` | `["x86_64"]` (unchanged, now load-bearing) |

No variable is renamed, added or removed. Call sites that already set
`lambda_packaging` explicitly are unaffected.

A call site that relied on the old default and points at a JVM tag **fails at
`terraform plan`**, by design — the packaging gate is what makes this a loud
break instead of four functions that apply clean and die on first invocation:

```
Error: Resource precondition failed
  lambda_packaging = "native" contradicts the image_uri tag "1.1.38".
```

Two ways forward:

- **Keep the JVM packaging.** Add `lambda_packaging = "jvm"` at the call site.
  The plan goes clean again and the only diff is the `tenx-retriever-packaging`
  tag value, which was already `jvm`.
- **Move to native** (recommended). Mirror `lambda-10x:<version>-native` into
  your private ECR, point `image_uri` at it, and leave `architectures` at
  `["x86_64"]`. The plan shows an in-place `image_uri` update on all four
  functions; no queue, role or function is replaced.

Only the second path changes what runs. Cold start drops from seconds to
sub-second; warm behaviour is identical, since both images carry the same engine
code.

## Upgrading from v1.x

v2.0.0 renames one input, one escape hatch and one tag key. Nothing else about
the deployed stack changes.

| v1.x | v2.0.0 |
|---|---|
| `runtime_flavor` | `lambda_packaging` |
| `allow_flavor_tag_mismatch` | `allow_packaging_tag_mismatch` |
| `tenx-retriever-runtime` tag | `tenx-retriever-packaging` tag |
| `terraform_data.flavor_gate` | `terraform_data.packaging_gate` |

Terraform has no variable aliasing, so both old names are hard errors from
`terraform validate` onward after the bump:

```
Error: Unsupported argument
  An argument named "runtime_flavor" is not expected here.
```

Rename the arguments at your call site and re-plan. Expect one in-place tag
update per resource (the old key is dropped, the new one added); no function,
queue or role is replaced. The gate resource rename is covered by a `moved`
block in the module, so existing state is carried across rather than
destroyed and recreated.

## ⚠ Recursion guard

When `source_bucket_name == index_bucket_name` (single-bucket layout),
the engine's index writes must land under a key prefix that does not
overlap with the S3 → SQS notification scope. Otherwise each engine
write re-triggers the indexer via SQS → Lambda → S3 → SQS → … in a
recursive loop.

The module enforces this by requiring `index_bucket_path` to be non-empty
in the single-bucket case. Engine writes are then prepended with that
path (e.g. `indexing-results/tenx/<target>/r/...`), keeping them outside
a sibling `source_prefix` like `raw/` or `app/`.

The module refuses the unsafe configuration at `terraform plan` time:

```
source_bucket_name == index_bucket_name requires a non-empty
index_bucket_path (e.g. "indexing-results/") to keep engine writes
outside the source notification scope.
```

Resolutions:
- Set `index_bucket_path` to a path that doesn't overlap with `source_prefix` (the default `"indexing-results/"` is safe)
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
| `lambda_packaging` | `"native"` | Which image `image_uri` points at — `native` (GraalVM `bootstrap`, sub-second cold start) or `jvm`. Sets the `tenx-retriever-packaging` tag on every resource so the deployed packaging is readable without inspecting the image, and is cross-checked against the `image_uri` tag at plan time. |
| `allow_packaging_tag_mismatch` | false | Escape hatch for that cross-check. Set true for a digest-pinned `image_uri`, or a retag into a registry that does not use the `-native` suffix. `lambda_packaging` is then unverified. |
| `architectures` | `["x86_64"]` | Exactly one of `["x86_64"]` or `["arm64"]`. The published native tag is amd64-only, so this default is the one the default packaging requires. `["arm64"]` is reachable only via `lambda_packaging = "jvm"` or a self-compiled arm64 binary; any other arm64 call site fails at `terraform plan`. |
| `allow_arm64_native` | false | Escape hatch for that arm64 refusal. Set true only when `image_uri` points at a native image you compiled for arm64 yourself. |
| `ephemeral_storage_mb` | null | Size of `/tmp`. Null keeps Lambda's 512 MB. The stream role stages fetched blobs there. |
| `image_entry_point` / `image_command` | `[]` | Override the image's ENTRYPOINT/CMD. Both published images already carry the right one; leave empty. |

## File layout

```
main.tf         ← resources (Lambdas, SQS, IAM, triggers) + the packaging gate
variables.tf    ← inputs
outputs.tf      ← outputs
versions.tf     ← provider constraints
README.md       ← this file
```

## License

This repository is licensed under the [MIT License](LICENSE).

### Important: Log10x Product License Required

This repository contains infrastructure tooling for Log10x Retriever. While the Terraform module
itself is open source, **using Log10x requires a commercial license**.

| Component | License |
|-----------|---------|
| This repository (Terraform module) | MIT (open source) |
| Log10x engine and runtime | Commercial license required |

**What this means:**
- You can freely use, modify, and distribute this Terraform module
- The Log10x software that consumes this infrastructure requires a paid subscription
- A valid Log10x API key is required to run the deployed software

**Get Started:**
- [Log10x Pricing](https://log10x.com/pricing)
- [Documentation](https://doc.log10x.com)
- [Contact Sales](mailto:sales@log10x.com)
