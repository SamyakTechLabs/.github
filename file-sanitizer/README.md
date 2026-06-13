# S3 File Sanitizer — Reusable Lambda

A drop-in AWS Lambda that **sanitizes uploaded files in place on S3**. Point it at
one or more buckets; every object created there is cleaned automatically — no
application code changes required.

- **PDF** — strips auto-actions (`/AA`, `/OpenAction`) and named actions (`/Names`) that can execute JavaScript.
- **Images** (`png jpg jpeg gif bmp webp tiff`) — re-renders pixel data through Pillow, dropping EXIF, metadata, and embedded payloads; downscales oversized images.
- **SVG** — whitelist-based tag/attribute filtering; strips `javascript:` and `data:` URI schemes.

It is **bucket- and region-agnostic** — the same deployment serves any number of
buckets, all configurable. Everything is plain `bash` + AWS CLI; the only Python
runs inside the Lambda.

```
file-sanitizer/
    lambda_function.py            # the sanitizer (generic; reads bucket/key from the event)
    requirements.txt              # Pillow, PyPDF2, defusedxml
    configure.sh                  # interactive — generates sanitizer.config
    deploy.sh                     # deploys role + layer + function + triggers
    sanitizer.config.example      # documented config template
```

## Contents

- [Quick start](#quick-start)
- [How it works](#how-it-works)
- [Configuration reference](#configuration-reference)
- [AWS permissions setup](#aws-permissions-setup)
- [Deployment](#deployment)
- [Verify the deployment](#verify-the-deployment)
- [Supported file types](#supported-file-types)
- [Failure behaviour](#failure-behaviour)
- [Testing with malicious files](#testing-with-malicious-files)
- [Caveats & limitations](#caveats--limitations)
- [Troubleshooting](#troubleshooting)

---

<a id="quick-start"></a>
## Quick start

```bash
cd file-sanitizer

# 1. Generate a config file interactively (region, bucket(s), naming, limits).
./configure.sh

# 2. Make sure your AWS CLI is authenticated (see "AWS permissions setup").
aws sts get-caller-identity

# 3. Deploy everything: IAM role, dependency layer, function, S3 triggers.
./deploy.sh
```

That's it. Upload a file to a configured bucket and it will be sanitized within a
few seconds.

For code-only updates afterwards (you changed `lambda_function.py`, nothing else):

```bash
./deploy.sh --skip-layer --skip-trigger
```

---

<a id="how-it-works"></a>
## How it works

1. A file is uploaded to a configured S3 bucket.
2. S3 fires an `ObjectCreated` event to the Lambda (optionally filtered to a key prefix).
3. The Lambda downloads the object and sanitizes it based on extension.
4. The cleaned object is written back with `ServerSideEncryption: AES256` and `sanitized: true` metadata.
5. On **any** failure (corrupt file, parse error, oversized) the object is **deleted** — unsafe content is never left in the bucket.

Objects already marked `sanitized: true` are skipped on re-triggers, so the
write-back in step 4 does not cause an infinite loop. Unsupported file types are
left untouched and reported as a success (not a failure).

---

<a id="configuration-reference"></a>
## Configuration reference

`deploy.sh` sources a shell config file (default `./sanitizer.config`). Generate
it with `./configure.sh`, or copy [`sanitizer.config.example`](./sanitizer.config.example)
and edit by hand. Every value can also be overridden with a command-line flag.

| Config key | Flag | Default | Description |
|---|---|---|---|
| `REGION` | `--region` | `ap-south-1` | Region for the Lambda **and all buckets**. |
| `BUCKETS` | `--bucket` (repeatable) | — (**required**) | Space-separated bucket names. All must be in `REGION`. |
| `FUNCTION_NAME` | `--function` | `s3-file-sanitizer` | Lambda function name. |
| `LAYER_NAME` | `--layer` | `s3-file-sanitizer-deps` | Dependency layer name. |
| `PREFIX` | `--prefix` | `""` (whole bucket) | Restrict the trigger to keys under this prefix, e.g. `uploads/`. |
| `MEMORY` | — | `512` | Lambda memory (MB). |
| `TIMEOUT` | — | `60` | Lambda timeout (seconds). |
| `RUNTIME` | — | `python3.11` | Python runtime (also selects the layer wheel target). |
| `MAX_FILE_SIZE_MB` | — | `50` | Largest object the function will process. Passed as a Lambda env var. |
| `MAX_IMAGE_DIMENSION` | — | `4096` | Max image width/height (px); larger images are downscaled. Lambda env var. |

Flags override config values. `--bucket` can be repeated and **replaces** (does
not append to) the config's `BUCKETS`:

```bash
./deploy.sh --region us-east-1 --bucket uploads-prod --bucket avatars-prod
```

`MAX_FILE_SIZE_MB` and `MAX_IMAGE_DIMENSION` are injected as Lambda environment
variables, so you can tune them later in the console without redeploying code.

---

<a id="aws-permissions-setup"></a>
## AWS permissions setup

There are **two** distinct identities involved. Don't confuse them.

### 1. The deploying identity (you / your CI user)

This is the IAM user or role whose credentials `aws configure` (or your CI
secrets) provide. `deploy.sh` uses it to create the role, publish the layer,
create the function, and wire the triggers. It needs:

```jsonc
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "LambdaManage",
      "Effect": "Allow",
      "Action": [
        "lambda:CreateFunction", "lambda:UpdateFunctionCode",
        "lambda:UpdateFunctionConfiguration", "lambda:GetFunction",
        "lambda:PublishLayerVersion", "lambda:ListLayerVersions",
        "lambda:AddPermission", "lambda:RemovePermission"
      ],
      "Resource": "*"
    },
    {
      "Sid": "IamManageExecutionRole",
      "Effect": "Allow",
      "Action": [
        "iam:CreateRole", "iam:GetRole", "iam:PassRole",
        "iam:AttachRolePolicy", "iam:PutRolePolicy"
      ],
      "Resource": "arn:aws:iam::*:role/s3-file-sanitizer-role*"
    },
    {
      "Sid": "S3ConfigureNotifications",
      "Effect": "Allow",
      "Action": [
        "s3:PutBucketNotification", "s3:GetBucketNotification"
      ],
      "Resource": "arn:aws:s3:::YOUR_BUCKET*"
    },
    {
      "Sid": "Identity",
      "Effect": "Allow",
      "Action": "sts:GetCallerIdentity",
      "Resource": "*"
    }
  ]
}
```

> Tighten `Resource` on the IAM and S3 statements to match the `FUNCTION_NAME`
> and bucket names you actually use. `iam:PassRole` is required so Lambda can
> assume the execution role you create. For a quick spike, the AWS-managed
> `IAMFullAccess` + `AWSLambda_FullAccess` + `AmazonS3FullAccess` will work, but
> the scoped policy above is the least-privilege option for production/CI.

**To authenticate locally:**

```bash
aws configure                 # paste an access key/secret for the deploying user
# or, for SSO:
aws sso login --profile my-profile && export AWS_PROFILE=my-profile
```

### 2. The Lambda execution role (created for you)

`deploy.sh` creates `<FUNCTION_NAME>-role` automatically and attaches:

- **`AWSLambdaBasicExecutionRole`** (managed) — CloudWatch Logs.
- An inline `s3-access` policy scoped to **only your configured buckets**:

```jsonc
{
  "Effect": "Allow",
  "Action": ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"],
  "Resource": ["arn:aws:s3:::BUCKET_A/*", "arn:aws:s3:::BUCKET_B/*"]
},
{
  "Effect": "Allow",
  "Action": ["s3:ListBucket"],
  "Resource": ["arn:aws:s3:::BUCKET_A", "arn:aws:s3:::BUCKET_B"]
}
```

You don't create this by hand — it's listed here so you know exactly what the
function can touch. Re-running `deploy.sh` after editing `BUCKETS` updates the
policy to match.

### 3. Resource-based permission for S3 → Lambda

For each bucket, `deploy.sh` adds a Lambda resource policy statement allowing
`s3.amazonaws.com` to `InvokeFunction`, scoped by `--source-arn` (the bucket) and
`--source-account` (your account). This is what lets the bucket's event
notification actually fire the function.

---

<a id="deployment"></a>
## Deployment

A single script handles everything — IAM role, dependency layer, function code,
and S3 triggers — and is safe to re-run (idempotent).

```bash
./deploy.sh                          # uses ./sanitizer.config
./deploy.sh --config prod.config     # use a specific config file
```

### What the script does

1. Validates AWS credentials via `sts get-caller-identity`.
2. Creates/updates the execution role with the scoped S3 policy + CloudWatch Logs.
3. Builds the dependency layer (`pip3 install` linux/x86_64 wheels → zip → publish), unless `--skip-layer`.
4. Packages `lambda_function.py` and creates/updates the function with your memory, timeout, runtime, layer, and `MAX_*` env vars.
5. For **each** bucket: grants the `InvokeFunction` permission and configures the `ObjectCreated` notification (with the optional prefix filter), unless `--skip-trigger`.

### All options

| Flag | Description |
|---|---|
| `--config FILE` | Config file to source (default `./sanitizer.config`). |
| `--region REGION` | Override region. |
| `--bucket BUCKET` | Override buckets; repeatable. |
| `--function NAME` | Override function name. |
| `--layer NAME` | Override layer name. |
| `--prefix PREFIX` | Override key prefix filter. |
| `--skip-layer` | Reuse the existing layer (code-only deploys). |
| `--skip-trigger` | Skip S3 notification setup. |
| `--help` | Show usage. |

---

<a id="verify-the-deployment"></a>
## Verify the deployment

Upload a test file, then confirm the metadata flag was set:

```bash
aws s3 cp test.pdf s3://YOUR_BUCKET/uploads/test.pdf --region YOUR_REGION
sleep 5
aws s3api head-object \
  --bucket YOUR_BUCKET \
  --key uploads/test.pdf \
  --region YOUR_REGION \
  --query 'Metadata'
```

Expected:

```json
{ "sanitized": "true", "request-id": "some-lambda-request-id" }
```

Tail the logs while testing:

```bash
aws logs tail /aws/lambda/YOUR_FUNCTION_NAME --follow --region YOUR_REGION
```

---

<a id="supported-file-types"></a>
## Supported file types

| Type | Extensions | What gets stripped |
|---|---|---|
| PDF | `.pdf` | Auto-actions, JavaScript triggers, named actions |
| Images | `.png` `.jpg` `.jpeg` `.gif` `.bmp` `.webp` `.tiff` | EXIF, metadata, embedded payloads; oversized images downscaled |
| SVG | `.svg` | All tags/attributes not on the whitelist; `javascript:` and `data:` URI schemes |

Anything else is **skipped** — left in S3 unchanged, Lambda returns success.

---

<a id="failure-behaviour"></a>
## Failure behaviour

If sanitization fails for any reason, the Lambda:

1. Logs the error to CloudWatch.
2. **Deletes the object from S3** — unsafe content is never served.
3. Returns a 400 (visible in the execution logs).

> Unsupported file types are **not** failures — they are skipped and left intact.

For production, set a CloudWatch alarm on the function's `Errors` metric.

---

<a id="testing-with-malicious-files"></a>
## Testing with malicious files

Replace `YOUR_BUCKET` / `YOUR_REGION` below.

### PDF — injected JavaScript

Tool: [JS2PDFInjector](https://github.com/cornerpirate/JS2PDFInjector) (needs Java).

```bash
echo 'app.alert("XSS test from PDF");' > test.js
java -jar JS2PDFInjector-1.0.jar base-document.pdf test.js
# Confirm payload present:
strings js_injected_base-document.pdf | grep -i "openaction\|javascript\|app.alert"

aws s3 cp js_injected_base-document.pdf s3://YOUR_BUCKET/uploads/test-infected.pdf --region YOUR_REGION
sleep 5
aws s3 cp s3://YOUR_BUCKET/uploads/test-infected.pdf sanitized.pdf --region YOUR_REGION
# No output = stripped:
strings sanitized.pdf | grep -i "openaction\|javascript\|app.alert"
```

### SVG — embedded script tag

```bash
cat > test-malicious.svg << 'EOF'
<svg xmlns="http://www.w3.org/2000/svg" width="100" height="100">
  <script type="text/javascript">alert('XSS')</script>
  <circle cx="50" cy="50" r="40" fill="green"/>
  <image href="javascript:alert('xss')"/>
  <a href="javascript:void(0)"><rect width="100" height="100"/></a>
</svg>
EOF

aws s3 cp test-malicious.svg s3://YOUR_BUCKET/uploads/test-malicious.svg --region YOUR_REGION
sleep 5
aws s3 cp s3://YOUR_BUCKET/uploads/test-malicious.svg sanitized.svg --region YOUR_REGION
cat sanitized.svg   # only the safe <circle> should remain
```

### Image — EXIF metadata strip

```bash
brew install exiftool   # macOS
exiftool -Comment="malicious payload" -Artist="attacker" \
         -XMP-dc:Description="<script>alert(1)</script>" test-image.jpg

aws s3 cp test-image.jpg s3://YOUR_BUCKET/uploads/test-image.jpg --region YOUR_REGION
sleep 5
aws s3 cp s3://YOUR_BUCKET/uploads/test-image.jpg sanitized-image.jpg --region YOUR_REGION
# No output = metadata removed:
exiftool sanitized-image.jpg | grep -E "Comment|Artist|Description"
```

---

<a id="caveats--limitations"></a>
## Caveats & limitations

**Existing bucket notifications.** `deploy.sh` uses
`put-bucket-notification-configuration`, which **replaces** a bucket's entire
notification config. If a target bucket already has other notifications (other
Lambdas, SQS, SNS), they will be **overwritten**. Check first:

```bash
aws s3api get-bucket-notification-configuration --bucket YOUR_BUCKET --region YOUR_REGION
```

If non-empty, wire this Lambda's notification into the existing config manually
(console or a merged JSON) rather than letting the script replace it, and run
`deploy.sh --skip-trigger`.

**Same-region only.** S3 → Lambda notifications require the function and the
bucket to be in the same region. Every bucket in `BUCKETS` must share `REGION`.
For buckets in another region, deploy a second instance with a different
`FUNCTION_NAME`/config.

**In-place mutation.** Files are overwritten in the same key. Don't point this at
a bucket where you need the byte-exact original preserved. (Versioned buckets keep
the pre-sanitization version, which you may want to lifecycle-expire.)

**x86_64 layer.** The dependency layer is built for `manylinux2014_x86_64`. If you
configure the function for `arm64`, rebuild the layer with matching wheels.

---

<a id="troubleshooting"></a>
## Troubleshooting

**Uploaded a file but nothing happened.**
- Confirm the trigger exists: `aws s3api get-bucket-notification-configuration --bucket YOUR_BUCKET --region YOUR_REGION`.
- If you set `PREFIX`, make sure your test key is under it.
- Check the function has the S3 invoke permission: `aws lambda get-policy --function-name YOUR_FUNCTION_NAME --region YOUR_REGION`.

**`AccessDenied` writing back / deleting.**
The execution role's S3 policy didn't include that bucket. Re-run `deploy.sh`
with the bucket present in `BUCKETS` to refresh the inline policy.

**Layer fails to import (`No module named PIL`).**
The layer wheels don't match the runtime. Rebuild without `--skip-layer` and make
sure `RUNTIME` matches the function's runtime (and CPU architecture).

**Deploy fails at `iam:CreateRole` / `iam:PassRole`.**
The deploying identity lacks IAM permissions — see [AWS permissions setup](#aws-permissions-setup).

**My other bucket notifications disappeared.**
See [Caveats & limitations](#caveats--limitations) — the notification config was
replaced. Re-add them and use `--skip-trigger` going forward.
