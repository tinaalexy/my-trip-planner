# Backend Specification

> Derived from goal-spec.md and aligned with frontend-spec.md. Serves the same 5 core features: auth, trip creation, trip list, day-by-day itinerary editing, and PDF export (PDF is client-side; the backend has no involvement).

## Tech Stack

| Concern | Choice | Reason |
|---------|--------|--------|
| Runtime | Python 3.12 | Current stable release; broad library support |
| Framework | FastAPI | Auto-generated OpenAPI docs; Pydantic validation built-in; fast to write |
| ORM + schemas | SQLModel | Combines SQLAlchemy table models and Pydantic request/response schemas in one class; created by the FastAPI author |
| Migrations | Alembic | Standard migration tool for SQLAlchemy; integrates with SQLModel |
| Database | SQLite | No server to install or run; single file on disk; sufficient for a personal app |
| Auth | PyJWT + passlib[bcrypt] | PyJWT is actively maintained; passlib handles bcrypt password hashing |
| ASGI server | Uvicorn | Runs the FastAPI app; `uvicorn[standard]` includes the faster C-based event loop |
| CORS | FastAPI `CORSMiddleware` | Allows the frontend origin to call the API; origins configured via env var |
| Validation | Pydantic v2 (via FastAPI + SQLModel) | Built into FastAPI; `alias_generator=to_camel` configured globally so all API request/response fields are camelCase |

## Architecture Overview

Single-process FastAPI app. No microservices or serverless for the 2-weekend timeline.

Layered structure:

```
app/
  routers/        # FastAPI APIRouter instances — one file per resource (auth, trips, activities)
  models/         # SQLModel table classes (define DB schema + serialization together)
  schemas/        # Pydantic models for requests/responses that aren't DB table models
  services/       # Business logic — no FastAPI or HTTP imports here
  dependencies/   # FastAPI dependency functions (get_db_session, get_current_user)
  core/           # Config (Settings via pydantic-settings), security utilities (JWT helpers)
  database.py     # SQLite engine + session factory
  main.py         # FastAPI app creation, router registration, exception handlers
alembic/          # Alembic migration environment and version files
alembic.ini       # Alembic configuration
```

Route handlers are thin: FastAPI validates the request body via the schema type annotation, the handler calls a service function, and returns the result. All database access goes through SQLModel inside services, using a session injected via dependency.

## Data Models

### User

| Field | Type | Constraints | Notes |
|-------|------|-------------|-------|
| id | uuid | PK, auto-generated | Stored as TEXT in SQLite |
| username | str | Unique, not null, indexed | 3–30 chars, alphanumeric + underscore (enforced in validation layer) |
| password_hash | str | Not null | passlib bcrypt hash; plain-text password never stored |
| created_at | datetime | Not null, default utcnow | |

### Trip

| Field | Type | Constraints | Notes |
|-------|------|-------------|-------|
| id | uuid | PK, auto-generated | |
| user_id | uuid | FK → User.id, not null, indexed | Cascade delete when user is deleted |
| destination | str | Not null | Max 100 chars (enforced in validation layer) |
| start_date | date | Not null | Date only (no time component) |
| end_date | date | Not null | Must be ≥ start_date (enforced in validation layer) |
| trip_type | str | Not null | Values: `solo`, `couple`, `family`, `group_of_friends`; validated via `Literal` type |
| created_at | datetime | Not null, default utcnow | |

### Activity

| Field | Type | Constraints | Notes |
|-------|------|-------------|-------|
| id | uuid | PK, auto-generated | |
| trip_id | uuid | FK → Trip.id, not null, indexed | Cascade delete when trip is deleted |
| day_index | int | Not null, ≥ 1 | 1 = start_date, 2 = start_date + 1 day, etc. |
| text | str | Not null | Max 300 chars (enforced in validation layer) |
| created_at | datetime | Not null, default utcnow | Used to order activities within a day (ascending) |
| updated_at | datetime | Not null, auto-updated | |

> **Field naming convention:** Python model fields are `snake_case` (internal convention). All API request bodies and response payloads serialize field names to `camelCase` via Pydantic's `alias_generator=to_camel` with `populate_by_name=True`. For example, the Python field `trip_id` is received and returned as `tripId` in JSON. This is set once in a shared `BaseModel` config and inherited by all schemas.

## Database

- **Engine:** SQLite — stored as a single file (`dev.db` locally; configurable via `DATABASE_URL`). No separate database server process required.
- **Connection:** SQLAlchemy engine created with `connect_args={"check_same_thread": False}` (required for SQLite when FastAPI handles requests across threads).
- **Migrations:** Alembic (`alembic revision --autogenerate` to generate; `alembic upgrade head` to apply). Migration files are committed to source control.
- **Indexes:**
  - `Trip.user_id` — supports the "list trips for a user" query
  - `Activity.trip_id` — supports the "fetch all activities for a trip" query
- **SQLite notes:** Enums stored as plain strings; UUIDs stored as TEXT — both handled transparently by SQLModel. SQLite allows only one concurrent writer; acceptable for a single-user personal app.

## Authentication & Authorization

- On signup: hash the password with bcrypt via `passlib` (cost factor 12), store the hash, return a signed JWT.
- On login: verify the username exists and `passlib.verify` succeeds, return a signed JWT.
- JWT payload: `{ "sub": user_id, "username": username }`. Signed with `JWT_SECRET` using HS256 via `PyJWT`. Default expiry: 7 days.
- All protected routes declare a `current_user: User = Depends(get_current_user)` dependency. `get_current_user` extracts and validates the Bearer token from the `Authorization` header and returns the user record.
- Authorization rule: a user may only read or mutate resources they own. Service functions verify `resource.user_id == current_user.id` before proceeding.
- A mismatch returns 404 (not 403) to avoid leaking resource existence.
- No roles or permissions beyond ownership for v1.
- JWTs are stateless and cannot be revoked. When a user logs out, the token is removed from the browser but remains cryptographically valid until expiry (7 days). This is an accepted tradeoff for v1; a production hardening step would introduce a server-side token denylist.

## Business Logic

- **Day index validation:** when adding or updating an activity, `day_index` must satisfy `1 ≤ day_index ≤ (trip.end_date - trip.start_date).days + 1`. The service layer enforces this after fetching the trip.
- **Trip ownership:** every trip and activity read/write checks that the authenticated user owns the parent trip. A mismatch returns 404.
- **Cascade deletes:** deleting a trip deletes all its activities (configured via SQLAlchemy `cascade="all, delete-orphan"` on the Trip → Activity relationship).
- **Activity ordering:** activities within a day are returned ordered by `created_at` ascending (insertion order).

## External Integrations

None for v1. PDF generation is handled entirely client-side by jsPDF + html2canvas.

## Background Jobs / Async Work

None for v1.

## Environment Variables

| Variable | Description |
|----------|-------------|
| `DATABASE_URL` | SQLite file path in SQLAlchemy format (e.g. `sqlite:///./dev.db`). Defaults to `sqlite:///./dev.db` if not set. |
| `JWT_SECRET` | Secret key used to sign and verify JWTs. Must be a long random string. |
| `JWT_EXPIRES_DAYS` | JWT lifetime in days. Defaults to `7` if not set. |
| `PORT` | HTTP port the server listens on. Defaults to `8000` if not set. |
| `CORS_ORIGINS` | Comma-separated list of allowed frontend origins (e.g. `http://localhost:5173,https://myapp.com`). In development, defaults to `http://localhost:5173`. |

Loaded via `pydantic-settings` (`BaseSettings` class in `app/core/config.py`), which reads from a `.env` file or the process environment.

## Error Handling Strategy

- FastAPI exception handlers registered in `main.py` catch typed exceptions and return consistent JSON error envelopes.
- **Pydantic `ValidationError`** → 422 with field-level error details (FastAPI handles this automatically).
- **`HTTPException(401)`** — raised by `get_current_user` on missing/invalid/expired token.
- **`HTTPException(404)`** — raised by service functions on resource not found or ownership mismatch.
- **Unexpected exceptions** → 500 in production (generic message; full traceback logged to `stderr`). In development, FastAPI's built-in debug mode includes tracebacks.
- Services raise `HTTPException` directly (acceptable for a small app); no custom error class hierarchy needed at this scale.
