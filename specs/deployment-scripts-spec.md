# Deployment Specification — my-trip-advisor

**Version:** 1.0  
**Status:** Draft  
**Scope:** All files required to build, provision, and deploy the application to AWS

---

## 1. Purpose

This document specifies the deployment pipeline for my-trip-advisor. It covers every file that moves code from a developer's machine to a running AWS environment: the Docker image that packages the backend, the CI workflow that validates every push, the CD workflow that ships green main-branch commits, the provisioning script that creates all AWS infrastructure, and the pre-push hook that catches problems before they reach CI.

The deployment targets a single AWS account using free-tier-eligible resources. All infrastructure is defined as CloudFormation and managed through a single shell script, so the environment can be created, updated, or torn down with one command.

---

## 2. Architecture Overview

The backend is a FastAPI application running as a Docker container on a single EC2 instance managed by ECS. The frontend is a React/Vite application served from S3 via CloudFront. The database is RDS PostgreSQL. Secrets — the database connection string and JWT signing key — are stored in AWS Secrets Manager and injected into the container at runtime; they never appear in plaintext in task definitions, environment files, or source code.

The EC2 instance has an Elastic IP so the backend URL remains stable across instance stops and restarts. CloudFront handles HTTPS termination for the frontend and rewrites 403 errors to `index.html` so React Router's client-side routing works correctly.

There is no staging environment. Deploys go directly to production on every green push to `main`.

---

## 3. Files in Scope

| File | Action required |
|------|-----------------|
| `backend/Dockerfile` | Create |
| `.github/workflows/ci.yml` | Already exists — no changes needed |
| `.github/workflows/cd.yml` | Edit to complete the deploy jobs |
| `scripts/aws-provision.sh` | Already exists |
| `scripts/pre-push.sh` | Already exists |

The CloudFormation template at `infrastructure/stack.yml` is already complete and is not changed by this spec.

---

## 4. `backend/Dockerfile`

The Dockerfile must produce a minimal, self-contained image that ECS can run without any external setup beyond environment variable injection.

**Base image.** Use `python:3.12-slim`. This is a minimal Debian image with Python 3.12 and no development tools, which keeps the image small and reduces the attack surface.

**Build process.** The image copies `requirements.txt` first and installs dependencies before copying the rest of the source. This ordering is intentional: Docker caches the dependency layer, so rebuilds are fast when only application code changes.

**Startup command.** On container start, the image must run `alembic upgrade head` before starting the application server. Alembic is idempotent — migrations already applied are skipped — so running it on every start ensures the database schema is always in sync with the deployed code without requiring a separate migration job or manual intervention.

The application server is uvicorn, bound to `0.0.0.0:8000`. Port 8000 must be exposed.

**What the image must not contain.** Development and test dependencies (`pytest`, `bandit`, `safety`, etc.) must not be installed. The image must not contain any `.env` file or hardcoded secrets. All runtime configuration — `DATABASE_URL`, `JWT_SECRET`, `JWT_EXPIRES_DAYS`, `CORS_ORIGINS`, `PORT` — comes from ECS task definition environment variables and Secrets Manager. There must be no `ENTRYPOINT`, so the startup command can be overridden in local testing with `docker run ... bash`.

---

## 5. `.github/workflows/ci.yml`

CI runs on every push to any branch and on every pull request targeting `main`. Its sole responsibility is validation — nothing is deployed here.

The workflow runs four jobs in parallel:

**Backend tests** installs Python 3.12 dependencies and runs `pytest --tb=short -q` against a SQLite test database. The job passes a minimal set of environment variables to satisfy the application's startup requirements: `DATABASE_URL=sqlite:///./test.db`, a 32-character JWT secret, `JWT_EXPIRES_DAYS=1`, and `CORS_ORIGINS=http://localhost:5173`.

**Backend security** runs `bandit` against `app/` at medium-severity level (skipping B101, which flags `assert` statements that are intentional in tests), runs `safety scan` to check for known CVEs in `requirements.txt`, and greps the source for patterns that suggest hardcoded passwords, secrets, or API keys.

**Frontend review** installs Node 22 dependencies via `npm ci`, runs `tsc --noEmit` to catch type errors, and runs the linter via `npm run lint`.

**Frontend security** installs dependencies and runs `npm audit --audit-level=moderate` to catch vulnerable packages, then greps `frontend/src/` for hardcoded tokens, keys, or secrets.

No AWS credentials are needed anywhere in this workflow.

---

## 6. `.github/workflows/cd.yml`

CD runs automatically after CI completes on `main`. Both deploy jobs must check that the triggering CI workflow concluded with `success` and do nothing otherwise.

**Trigger.** The workflow is triggered by `workflow_run` on the CI workflow, filtered to `main` and the `completed` event type.

**AWS authentication.** The organisation SCP blocks GitHub's OIDC provider, so both jobs authenticate using long-lived IAM access keys stored as GitHub Secrets (`AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `AWS_REGION`). Neither job should include `permissions: id-token: write` or any `role-to-assume` configuration — doing so would indicate an incorrect authentication method.

**GitHub Secrets required.** Before CD can run, the following secrets must be added to the repository. Their values come from the output of `aws-provision.sh`:

| Secret | Value source |
|--------|--------------|
| `AWS_ACCESS_KEY_ID` | IAM user `my-trip-advisor-deploy` |
| `AWS_SECRET_ACCESS_KEY` | Same |
| `AWS_REGION` | The region used during provisioning |
| `ECR_REPOSITORY` | ECR repository name printed by `aws-provision.sh` |
| `ECS_CLUSTER` | ECS cluster name printed by `aws-provision.sh` |
| `ECS_SERVICE` | ECS service name printed by `aws-provision.sh` |
| `ECS_TASK_FAMILY` | `my-trip-advisor-backend` |
| `S3_BUCKET` | S3 bucket name printed by `aws-provision.sh` |
| `CLOUDFRONT_DISTRIBUTION_ID` | Distribution ID printed by `aws-provision.sh` |
| `VITE_API_BASE_URL` | Elastic IP URL printed by `aws-provision.sh` |

### 6.1 Backend deploy job (`deploy-backend`)

This job builds a new Docker image, registers it with ECS, and waits for the service to stabilise.

It checks out the triggering commit, logs in to ECR, then builds and pushes the Docker image with two tags: one using the commit SHA (used in the task definition for an immutable reference) and one as `latest` (for convenience). The commit-SHA tag must be used in the task definition — not `latest` — so rollbacks are unambiguous.

To update ECS, the job fetches the current task definition JSON, replaces the container image URI with the new commit-SHA tag, strips the read-only fields that AWS adds (`taskDefinitionArn`, `revision`, `status`, `requiresAttributes`, `compatibilities`, `registeredAt`, `registeredBy`), and registers the modified JSON as a new task definition revision. It then calls `aws ecs update-service --force-new-deployment` pointing to the new revision and waits for `aws ecs wait services-stable` to return before continuing.

Finally, the job resolves the EC2 instance's public DNS name from the running ECS task and polls `GET http://<ec2-dns>/health` up to five times, fifteen seconds apart. If no HTTP 200 is received, the job fails.

### 6.2 Frontend deploy job (`deploy-frontend`)

This job builds the React application and publishes it to S3 and CloudFront.

It checks out the triggering commit, installs Node 22 dependencies, then builds the frontend with `VITE_API_BASE_URL` set to the backend's Elastic IP URL from Secrets. The build output is in `dist/`.

The job syncs `dist/` to S3 in two passes to set appropriate cache headers. All files except `index.html` receive `Cache-Control: public, max-age=31536000, immutable` — these files have content-hashed names, so they are safe to cache forever. `index.html` receives `Cache-Control: no-cache, no-store, must-revalidate` so browsers always fetch the latest app shell, which in turn loads the hashed assets.

After the S3 sync, the job creates a CloudFront invalidation for `/*` to clear edge caches. It then polls `GET https://<cloudfront-domain>` up to five times, fifteen seconds apart, and fails if no HTTP 200 is received.

---

## 7. `scripts/aws-provision.sh`

This script is the single interface for managing all AWS infrastructure. Running it without arguments creates the stack on first run and updates it on subsequent runs. It accepts two flags: `--delete` to tear down the stack, and `--outputs` to print the current stack outputs without making any changes.

**Prerequisite.** The script requires an AWS CLI profile named `aws-free-tier` configured via `aws configure --profile aws-free-tier`. It checks credentials at startup by calling `aws sts get-caller-identity` and fails immediately with a clear message if the profile is missing or invalid.

**What it does, in order:**

1. Verifies AWS credentials, as described above.

2. Discovers the default VPC ID and subnet IDs in the target region. These are required CloudFormation parameters. The script fails with a clear message if no default VPC exists, since the CloudFormation template does not create one.

3. Generates a random 16-character alphanumeric database password and a 64-character hex JWT secret, saves them to `.aws-state.env` in the repo root, and reuses the existing values on all subsequent runs. `.aws-state.env` is gitignored and must never be committed.

4. Deploys the CloudFormation stack at `infrastructure/stack.yml`. On the first run it calls `create-stack`; on subsequent runs it calls `update-stack`. It waits for the operation to complete and treats "No updates to be performed" as success.

5. Reads the stack outputs (ECR URI, S3 bucket name, CloudFront distribution ID and domain, Elastic IP URL, ECS cluster and service names), saves them to `.aws-state.env`, and prints a formatted table of all the GitHub Secrets the developer needs to add to the repository.

**Teardown.** Running with `--delete` asks for confirmation by requiring the developer to type the stack name. A mismatch cancels the operation with no changes. On confirmation, it deletes the CloudFormation stack. Resources with `DeletionPolicy: Retain` survive deletion — the ECR repository, S3 bucket, RDS final snapshot, and CloudWatch log group must be deleted manually in the AWS Console if a full clean-up is needed.

**Error handling.** Every fatal error calls a `die` function that prints a human-readable message and exits non-zero. The script never silently continues past a failure. If the stack is in an unexpected state (such as `ROLLBACK_IN_PROGRESS`), the script tells the developer to clean up manually rather than attempting automatic recovery.

---

## 8. `scripts/pre-push.sh`

This script is a Git pre-push hook that mirrors the CI workflow locally. Its purpose is to catch failures before a push so that CI is never the first place a developer learns about a broken build.

Running `bash scripts/pre-push.sh --install` installs it as `.git/hooks/pre-push`.

**Checks run, in order:** backend tests via pytest, backend static analysis via bandit, backend dependency scanning via safety, backend hardcoded-secret grep, frontend type-checking via tsc, frontend linting via npm run lint, frontend dependency scanning via npm audit, and frontend hardcoded-secret grep.

All checks run regardless of whether earlier ones fail. Failures are collected and printed together at the end so the developer sees every problem at once rather than fixing one at a time. The hook exits non-zero if any check failed, which prevents the push.

`bandit` and `safety` are optional — if not installed they emit a warning and are skipped, but the hook still runs the remaining checks.

---

## 9. Acceptance Criteria

The deployment pipeline is considered complete when all of the following are true:

- `docker build -t test ./backend` exits 0.
- Starting the built container with `DATABASE_URL=sqlite:///./test.db` and a test JWT secret and calling `GET http://localhost:8000/health` returns HTTP 200.
- The CD workflow file contains no reference to `AWS_GITHUB_ACTIONS_ROLE_ARN` or `role-to-assume`.
- Pushing to any branch other than `main` triggers CI but not CD.
- Pushing to `main` with all CI checks passing triggers CD, which runs both `deploy-backend` and `deploy-frontend` to completion.
- After a successful CD run, `GET http://<ElasticIP>/health` returns `{"status": "ok"}`.
- After a successful CD run, the CloudFront URL loads the React application.
