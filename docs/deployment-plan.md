# Deployment Plan

> **Stack:** React/Vite → S3 + CloudFront | FastAPI → ECS EC2 (t2.micro) + RDS PostgreSQL  
> **IaC:** AWS CloudFormation (`infrastructure/stack.yml`)  
> **Auth:** AWS IAM Identity Center (SSO) locally, GitHub OIDC in CI — no long-term keys anywhere  
> **Secrets:** AWS Secrets Manager — never in environment variables or code

---

## Architecture

```
Browser
  │
  ├── HTTPS → CloudFront → S3 (React SPA)
  │
  └── HTTP  → Elastic IP → EC2 t2.micro (ECS) → FastAPI container
                                                      │
                                              Secrets Manager
                                              (DATABASE_URL, JWT_SECRET)
                                                      │
                                              RDS PostgreSQL (private subnet)
```

---

## Prerequisites — one-time code changes

### 1. `backend/app/database.py` — make `connect_args` conditional

SQLite needs `check_same_thread=False`; PostgreSQL rejects it.

```python
from sqlmodel import create_engine, Session
from app.core.config import settings

_connect_args = {"check_same_thread": False} if settings.database_url.startswith("sqlite") else {}
engine = create_engine(settings.database_url, connect_args=_connect_args)

def get_session():
    with Session(engine) as session:
        yield session
```

### 2. `backend/requirements.txt` — add PostgreSQL driver

```
psycopg2-binary>=2.9
```

### 3. Alembic — initialise and wire to settings

```bash
cd backend
alembic init alembic
```

Edit `alembic/env.py`:

```python
from app.core.config import settings
from app.models.user import User
from app.models.trip import Trip
from app.models.activity import Activity
from sqlmodel import SQLModel

config.set_main_option("sqlalchemy.url", settings.database_url)
target_metadata = SQLModel.metadata
```

Clear the placeholder URL in `alembic.ini`:
```ini
sqlalchemy.url =
```

Generate and apply the initial migration locally:
```bash
alembic revision --autogenerate -m "initial schema"
alembic upgrade head
```

Commit the generated `alembic/versions/` files.

---

## Deployment workflow

### Step 1 — Set up AWS SSO profile (once per machine)

```bash
bash scripts/aws-sso-setup.sh
```

- Guides through enabling IAM Identity Center in the AWS Console
- Creates a `trip-advisor` CLI profile using short-lived SSO tokens
- **No long-term keys stored** — credentials expire and are refreshed via browser login
- Refresh when the session expires (~8 hours): `bash scripts/aws-sso-setup.sh --login`

### Step 2 — Provision all infrastructure (CloudFormation)

```bash
bash scripts/aws-provision.sh
```

CloudFormation (`infrastructure/stack.yml`) creates everything in dependency order:

| Resource | Type | Notes |
|----------|------|-------|
| ECR repository | `AWS::ECR::Repository` | Lifecycle policy: keep last 10 images |
| S3 bucket | `AWS::S3::Bucket` | Public access blocked; OAC-only |
| CloudFront OAC + distribution | `AWS::CloudFront::*` | HTTPS redirect; React Router 403→200 |
| EC2 security group | `AWS::EC2::SecurityGroup` | Port 80 inbound |
| RDS security group | `AWS::EC2::SecurityGroup` | Port 5432 from EC2 SG only |
| RDS subnet group + PostgreSQL | `AWS::RDS::*` | db.t3.micro, private |
| Secrets Manager | `AWS::SecretsManager::Secret` | DATABASE_URL + JWT_SECRET |
| ECS execution role | `AWS::IAM::Role` | Pulls ECR image + reads secrets |
| EC2 instance role + profile | `AWS::IAM::*` | Registers with ECS cluster |
| GitHub OIDC provider + role | `AWS::IAM::*` | CI/CD without stored keys |
| ECS cluster | `AWS::ECS::Cluster` | |
| CloudWatch log group | `AWS::Logs::LogGroup` | 30-day retention |
| ECS task definition | `AWS::ECS::TaskDefinition` | Secrets from Secrets Manager |
| Elastic IP | `AWS::EC2::EIP` | Stable backend URL across restarts |
| EC2 t2.micro (ECS-optimized) | `AWS::EC2::Instance` | Free tier (750 hrs/month) |
| ECS service | `AWS::ECS::Service` | 1 task, EC2 launch type |

The script prints the full GitHub Secrets table at the end.

### Step 3 — Add GitHub Secrets

After provisioning, add the secrets printed by `aws-provision.sh` to:  
**GitHub → Settings → Secrets and variables → Actions**

With OIDC (recommended — no access keys):

| Secret | Value |
|--------|-------|
| `AWS_GITHUB_ACTIONS_ROLE_ARN` | From stack output |
| `AWS_REGION` | `ap-southeast-2` |
| `ECR_REPOSITORY` | `my-trip-advisor-backend` |
| `ECS_CLUSTER` | `my-trip-advisor` |
| `ECS_SERVICE` | `my-trip-advisor-backend` |
| `ECS_TASK_FAMILY` | `my-trip-advisor-backend` |
| `S3_BUCKET` | From stack output |
| `CLOUDFRONT_DISTRIBUTION_ID` | From stack output |
| `VITE_API_BASE_URL` | From stack output (Elastic IP URL) |

### Step 4 — First deploy

Push to `main`. The CI pipeline runs tests and checks first, then the CD pipeline:

1. **Backend** — builds Docker image → pushes to ECR → registers new ECS task definition revision → `ecs update-service` → waits for service to stabilise → smoke-tests `/health`
2. **Frontend** — `npm run build` → syncs to S3 → CloudFront invalidation → smoke-tests CloudFront URL

---

## Re-deploying (automated)

Every push to `main` that passes CI triggers a full deploy automatically.

Manual override if needed:
```bash
# Force a backend redeploy from the current image
aws ecs update-service --cluster my-trip-advisor \
  --service my-trip-advisor-backend --force-new-deployment \
  --profile trip-advisor --region ap-southeast-2

# Force a frontend redeploy
cd frontend && npm run build
aws s3 sync dist/ s3://<bucket> --delete --profile trip-advisor
aws cloudfront create-invalidation --distribution-id <id> --paths "/*" --profile trip-advisor
```

---

## Teardown

```bash
bash scripts/aws-provision.sh --delete
```

Resources with `DeletionPolicy: Retain` are preserved (ECR, S3, RDS snapshot, CloudWatch logs) — delete them manually if needed.

---

## Verification checklist

- [ ] `alembic upgrade head` succeeds against local SQLite
- [ ] `docker build -t test ./backend` exits 0
- [ ] Container smoke test: `docker run -e DATABASE_URL=sqlite:///./test.db -e JWT_SECRET=test1234567890123456789012345678 -p 8000:8000 test` → `curl http://localhost:8000/health` returns 200
- [ ] CloudFormation stack status: `CREATE_COMPLETE` or `UPDATE_COMPLETE`
- [ ] ECS service shows 1 running task
- [ ] `curl http://<ElasticIP>/health` returns `{"status":"ok"}`
- [ ] `POST http://<ElasticIP>/api/v1/auth/signup` returns 201
- [ ] CloudFront URL loads the React app
- [ ] Full happy path: login → create trip → add activity → export PDF
