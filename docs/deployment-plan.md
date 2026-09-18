# AWS Deployment Plan

> Backend: AWS App Runner + RDS PostgreSQL  
> Frontend: S3 + CloudFront  
> Local dev keeps SQLite — no dev workflow changes.

---

## 1. Code Changes Required

### 1.1 `backend/app/database.py` — make `connect_args` conditional

`connect_args={"check_same_thread": False}` is SQLite-only; PostgreSQL rejects it.

```python
from sqlmodel import create_engine, Session
from app.core.config import settings

_connect_args = {"check_same_thread": False} if settings.database_url.startswith("sqlite") else {}

engine = create_engine(settings.database_url, connect_args=_connect_args)

def get_session():
    with Session(engine) as session:
        yield session
```

### 1.2 `backend/requirements.txt` — add PostgreSQL driver

```
psycopg2-binary>=2.9
```

SQLAlchemy/SQLModel automatically uses the correct driver based on the `DATABASE_URL` scheme (`sqlite://` vs `postgresql://`). No other dependency changes needed.

### 1.3 Alembic — initialize and wire to settings

`alembic.ini` exists but `alembic init` has never been run. Run once on the dev machine:

```bash
cd backend
alembic init alembic
```

Then edit **`alembic/env.py`** — replace the metadata block with:

```python
from app.core.config import settings
from app.models.user import User          # registers table with SQLModel.metadata
from app.models.trip import Trip
from app.models.activity import Activity
from sqlmodel import SQLModel

config.set_main_option("sqlalchemy.url", settings.database_url)
target_metadata = SQLModel.metadata
```

Clear the placeholder in **`alembic.ini`** (env.py overrides it at runtime):

```ini
sqlalchemy.url =
```

Generate and apply the initial migration locally:

```bash
alembic revision --autogenerate -m "initial schema"
alembic upgrade head
```

Commit the generated `alembic/versions/` file to source control.

### 1.4 `backend/Dockerfile` — new file

```dockerfile
FROM python:3.12-slim

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY . .

EXPOSE 8000
CMD ["sh", "-c", "alembic upgrade head && uvicorn app.main:app --host 0.0.0.0 --port 8000"]
```

`alembic upgrade head` runs on every container start — safe because Alembic is idempotent (already-applied migrations are skipped).

### 1.5 `backend/.env.production.example` — new file (committed without real values)

```
DATABASE_URL=postgresql://myuser:mypassword@<rds-endpoint>:5432/tripplanner
JWT_SECRET=<long-random-string-min-32-chars>
JWT_EXPIRES_DAYS=7
PORT=8000
CORS_ORIGINS=https://<cloudfront-domain>
```

---

## 2. What Does NOT Change

| File / Area | Reason |
|-------------|--------|
| `app/core/config.py` | `DATABASE_URL` is already read from env; no code change needed |
| `app/models/` | SQLModel models are DB-agnostic |
| `app/routers/`, `services/`, `schemas/` | No DB-engine-specific code |
| `tests/conftest.py` | Tests keep using `sqlite:///:memory:` — no regression |
| Frontend source code | Only the `VITE_API_BASE_URL` env var changes at build time |

---

## 3. AWS Infrastructure Setup (in order)

### Step 1 — RDS PostgreSQL

1. AWS Console → RDS → **Create database**
2. Engine: PostgreSQL 16 · Template: **Free tier**
3. Instance: `db.t3.micro` · Storage: 20 GB gp2
4. DB name: `tripplanner` · Set master username + password (save these)
5. VPC: default VPC · **Publicly accessible: No** (App Runner uses a VPC connector — see Step 3)
6. Note the endpoint hostname once the instance is available

### Step 2 — ECR repository + push Docker image

```bash
# One-time: create the repository
aws ecr create-repository --repository-name my-trip-advisor-backend --region eu-west-1

# Authenticate, build, and push
aws ecr get-login-password --region eu-west-1 \
  | docker login --username AWS --password-stdin <account-id>.dkr.ecr.eu-west-1.amazonaws.com

docker build -t my-trip-advisor-backend ./backend
docker tag my-trip-advisor-backend:latest \
  <account-id>.dkr.ecr.eu-west-1.amazonaws.com/my-trip-advisor-backend:latest
docker push \
  <account-id>.dkr.ecr.eu-west-1.amazonaws.com/my-trip-advisor-backend:latest
```

### Step 3 — App Runner VPC connector

App Runner runs outside the VPC by default; a connector lets it reach the private RDS instance.

AWS Console → App Runner → **VPC connectors** → Create:
- VPC: same VPC as the RDS instance
- Subnets: the private subnets where RDS lives
- Security group: one that allows outbound TCP 5432 to the RDS security group

### Step 4 — App Runner service

AWS Console → App Runner → **Create service**:
- Source: Container registry → ECR → select the image from Step 2
- Port: `8000`
- **Environment variables** (set all from `.env.production.example`):
  - `DATABASE_URL` → `postgresql://myuser:mypassword@<rds-endpoint>:5432/tripplanner`
  - `JWT_SECRET` → long random string (32+ chars)
  - `JWT_EXPIRES_DAYS` → `7`
  - `PORT` → `8000`
  - `CORS_ORIGINS` → `https://<cloudfront-domain>` ← fill in after Step 6; update and redeploy
- Networking → Custom VPC → select the connector from Step 3
- Note the App Runner service URL (e.g. `https://abc123.eu-west-1.awsapprunner.com`)

### Step 5 — S3 bucket for frontend

```bash
# Build the React app with the App Runner URL
cd frontend
VITE_API_BASE_URL=https://abc123.eu-west-1.awsapprunner.com/api/v1 npm run build

# Create bucket (name must be globally unique)
aws s3 mb s3://my-trip-advisor-frontend --region eu-west-1

# Upload build output
aws s3 sync dist/ s3://my-trip-advisor-frontend --delete
```

Keep **Block all public access** enabled on the bucket — CloudFront serves it via OAC.

### Step 6 — CloudFront distribution

AWS Console → CloudFront → **Create distribution**:
- Origin domain: the S3 bucket
- Origin access: **Origin Access Control (OAC)** — auto-creates the bucket policy
- Default root object: `index.html`
- Custom error response: HTTP 403 → `/index.html` (response code 200) — required for React Router client-side routing
- Note the CloudFront domain (e.g. `https://d1abc.cloudfront.net`)

Go back to App Runner → update `CORS_ORIGINS` to `https://d1abc.cloudfront.net` → redeploy.

---

## 4. GitHub Secrets (required before CD pipeline works)

Set these in **GitHub → Settings → Secrets and variables → Actions**:

| Secret | Where to find it |
|--------|-----------------|
| `AWS_ACCESS_KEY_ID` | IAM user with the permissions below |
| `AWS_SECRET_ACCESS_KEY` | Same IAM user |
| `AWS_REGION` | e.g. `eu-west-1` |
| `ECR_REGISTRY` | `<account-id>.dkr.ecr.<region>.amazonaws.com` |
| `ECR_REPOSITORY` | `my-trip-advisor-backend` |
| `APP_RUNNER_SERVICE_ARN` | App Runner console → service → ARN |
| `S3_BUCKET` | e.g. `my-trip-advisor-frontend` |
| `CLOUDFRONT_DISTRIBUTION_ID` | CloudFront console → distribution ID |
| `VITE_API_BASE_URL` | App Runner service URL + `/api/v1` |

**Minimum IAM permissions** for the CD user:

```json
{
  "Effect": "Allow",
  "Action": [
    "ecr:GetAuthorizationToken",
    "ecr:BatchCheckLayerAvailability",
    "ecr:InitiateLayerUpload",
    "ecr:UploadLayerPart",
    "ecr:CompleteLayerUpload",
    "ecr:PutImage",
    "apprunner:StartDeployment",
    "apprunner:DescribeService",
    "s3:PutObject",
    "s3:DeleteObject",
    "s3:ListBucket",
    "cloudfront:CreateInvalidation"
  ],
  "Resource": "*"
}
```

---

## 5. Redeployment Workflow (automated via CD pipeline)

Every push to `main` that passes CI automatically:

1. **Backend** — builds Docker image, tags with git SHA + `latest`, pushes to ECR, triggers App Runner deployment, waits for it to go live, smoke-tests `/health`
2. **Frontend** — builds React app with `VITE_API_BASE_URL`, syncs `dist/` to S3, invalidates CloudFront cache

Manual override if needed:

```bash
# Force a backend redeploy from the current ECR image
aws apprunner start-deployment --service-arn <service-arn>

# Force a frontend redeploy
cd frontend && npm run build
aws s3 sync dist/ s3://my-trip-advisor-frontend --delete
aws cloudfront create-invalidation --distribution-id <dist-id> --paths "/*"
```

---

## 6. Verification Checklist

- [ ] `alembic upgrade head` runs without errors against local SQLite
- [ ] `docker build -t test ./backend` exits 0
- [ ] Container smoke test: `docker run -e DATABASE_URL=sqlite:///./test.db -e JWT_SECRET=test1234567890 -p 8000:8000 test` → `curl http://localhost:8000/docs` returns 200
- [ ] App Runner service status shows **Running**
- [ ] App Runner logs show `alembic upgrade head` completing successfully (not a connection error)
- [ ] `POST /api/v1/auth/signup` from the App Runner URL returns 201
- [ ] CloudFront URL loads the React app
- [ ] Full happy path: login → create trip → add activity → export PDF
