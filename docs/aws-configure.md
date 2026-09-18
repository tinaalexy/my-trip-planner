# AWS Profile Setup

How to configure the `aws-free-tier` profile used by `aws-provision.sh`.

---

## Prerequisites

- An AWS Free Tier account — sign up at **aws.amazon.com/free** if you don't have one
- AWS CLI v2 installed (see Step 1 below)

---

## Step 1 — Install the AWS CLI

**Windows:**
```
winget install Amazon.AWSCLI
```

Close and reopen your terminal after installing, then confirm it worked:
```bash
aws --version
# Expected: aws-cli/2.x.x ...
```

---

## Step 2 — Create an IAM user in the AWS Console

The AWS CLI needs an IAM user's access keys to authenticate. The root account email/password cannot be used here.

1. Sign in to the **AWS Console** at console.aws.amazon.com
2. Search for **IAM** in the top search bar → open it
3. Click **Users** in the left menu → **Create user**
4. Username: `my-trip-advisor-deploy` → click **Next**
5. Select **Attach policies directly**
6. Search for and tick each of these policies:
   - `AmazonEC2ContainerRegistryFullAccess`
   - `AmazonS3FullAccess`
   - `AmazonRDSFullAccess`
   - `AmazonVPCFullAccess`
   - `AmazonECS_FullAccess`
   - `IAMFullAccess`
   - `CloudFrontFullAccess`
   - `CloudWatchLogsFullAccess`
   - `AWSCloudFormationFullAccess`
   - `SecretsManagerReadWrite`
7. Click **Next** → **Create user**

---

## Step 3 — Create an access key for the IAM user

1. Click on the **`my-trip-advisor-deploy`** user you just created
2. Go to the **Security credentials** tab
3. Scroll down to **Access keys** → click **Create access key**
4. Use case: select **Command Line Interface (CLI)** → Next → Create
5. **Download the `.csv` file** — the secret access key is only shown once

You will need:
- **Access Key ID** — starts with `AKIA...`
- **Secret Access Key** — a long random string

---

## Step 4 — Configure the AWS CLI profile

Run this command in your terminal:

```bash
aws configure --profile aws-free-tier
```

Enter the values when prompted:

```
AWS Access Key ID:      AKIA...          (from the .csv file)
AWS Secret Access Key:  xxxxxxxxxx       (from the .csv file)
Default region name:    ap-southeast-2
Default output format:  json
```

---

## Step 5 — Verify it works

```bash
aws sts get-caller-identity --profile aws-free-tier
```

Expected output:
```json
{
    "Account": "103714493047",
    "Arn": "arn:aws:iam::103714493047:user/my-trip-advisor-deploy",
    "UserId": "..."
}
```

If you see an error, double-check the Access Key ID and Secret Access Key in `~/.aws/credentials`.

---

## Rotating your keys

Access keys should be rotated periodically or if they are ever exposed.

1. **AWS Console → IAM → Users → `my-trip-advisor-deploy` → Security credentials**
2. Make the current key **Inactive**
3. **Create access key** → download the new `.csv`
4. Update the profile with the new keys:

```bash
aws configure set aws_access_key_id     AKIA...    --profile aws-free-tier
aws configure set aws_secret_access_key xxxxxxxx   --profile aws-free-tier
```

---

## Where credentials are stored

The AWS CLI saves credentials in two files on your machine:

| File | Contents |
|------|----------|
| `~/.aws/credentials` | Access Key ID and Secret Access Key |
| `~/.aws/config` | Region and output format |

These files are on your local machine only and are never committed to git.

---

## Next step

Once the profile is configured, provision all AWS infrastructure:

```bash
bash scripts/aws-provision.sh
```
