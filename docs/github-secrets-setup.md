# GitHub Secrets Setup

Add these secrets to your repository before the CD pipeline can deploy.

Go to: **GitHub repo → Settings → Secrets and variables → Actions → New repository secret**

---

## Option A — GitHub CLI (recommended)

Requires the [GitHub CLI](https://cli.github.com) installed and authenticated (`gh auth login`).

Run once from the repo root after `aws-provision.sh` has completed:

```bash
# Read the values provisioning saved to .aws-state.env
source .aws-state.env

gh secret set AWS_REGION                   --body "ap-southeast-2"
gh secret set ECR_REPOSITORY              --body "my-trip-advisor-backend"
gh secret set ECS_CLUSTER                 --body "$ECS_CLUSTER"
gh secret set ECS_SERVICE                 --body "$ECS_SERVICE"
gh secret set ECS_TASK_FAMILY             --body "my-trip-advisor-backend"
gh secret set S3_BUCKET                   --body "$S3_BUCKET"
gh secret set CLOUDFRONT_DISTRIBUTION_ID  --body "$CF_DIST_ID"
gh secret set VITE_API_BASE_URL           --body "$BACKEND_URL"

# These two come from your IAM user — enter when prompted
gh secret set AWS_ACCESS_KEY_ID
gh secret set AWS_SECRET_ACCESS_KEY
```

Running `gh secret set` without `--body` prompts for the value without echoing it to the terminal.

---

## Option B — Manual via the GitHub UI

1. Open your repository on GitHub.
2. Click **Settings** → **Secrets and variables** → **Actions**.
3. Click **New repository secret** for each row below.

| Secret name | Where to find the value |
|-------------|------------------------|
| `AWS_REGION` | `ap-southeast-2` |
| `AWS_ACCESS_KEY_ID` | AWS Console → IAM → Users → `my-trip-advisor-deploy` → Security credentials |
| `AWS_SECRET_ACCESS_KEY` | Same — only visible at creation time |
| `ECR_REPOSITORY` | `my-trip-advisor-backend` |
| `ECS_CLUSTER` | Printed by `aws-provision.sh` (also in `.aws-state.env`) |
| `ECS_SERVICE` | Printed by `aws-provision.sh` (also in `.aws-state.env`) |
| `ECS_TASK_FAMILY` | `my-trip-advisor-backend` |
| `S3_BUCKET` | Printed by `aws-provision.sh` (also in `.aws-state.env`) |
| `CLOUDFRONT_DISTRIBUTION_ID` | Printed by `aws-provision.sh` (also in `.aws-state.env`) |
| `VITE_API_BASE_URL` | Printed by `aws-provision.sh` — the Elastic IP URL, e.g. `http://3.104.87.170/api/v1` |

---

## Verification

After adding all secrets, trigger the CD pipeline by pushing to `main` with CI green, or check the list:

```bash
gh secret list
```

All 10 secrets should appear.
