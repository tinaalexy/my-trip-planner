# My Trip Planner — Implementation Plan

## Overview

| Phase | Name | Est. Time | Key Output |
|-------|------|-----------|------------|
| 1 | Project setup | 1–2 h | Scaffolded repos, deps installed, Vite proxy, Alembic init |
| 2 | Backend: data models + migrations | 1 h | User, Trip, Activity tables in dev.db |
| 3 | Backend: auth endpoints | 1.5 h | POST /auth/signup and /auth/login returning JWT |
| 4 | Backend: auth dependency | 0.5 h | get_current_user dep; 401 on bad token |
| 5 | Backend: trips endpoints | 1.5 h | GET/POST /trips, GET/DELETE /trips/:tripId |
| 6 | Backend: activities endpoints | 1.5 h | POST/PUT/DELETE /trips/:tripId/activities/:id |
| 7 | Frontend: core infrastructure | 2 h | Axios, AuthContext, ProtectedRoute, AppShell, router |
| 8 | Frontend: shared UI components | 1 h | Button, TextInput, DateInput, PageHeading, ErrorBanner |
| 9 | Frontend: auth pages | 1.5 h | LoginPage, SignupPage, expired-session banner |
| 10 | Frontend: trips list + create | 2 h | TripsPage, CreateTripPage, TripCard, TripForm |
| 11 | Frontend: itinerary + activities | 2 h | TripPage, TripHeader, DayPanel, ActivityItem, ActivityInput |
| 12 | PDF export | 1 h | ExportButton, html2canvas capture, jsPDF download |
| 13 | Polish + responsive | 1.5 h | Tailwind breakpoints, spinners, full AC smoke test |

**Total estimate: ~18 hours (2 weekends)**

---

## Phase 1 — Project Setup

### What to build
Two sibling directories: `backend/` (FastAPI) and `frontend/` (React + Vite), both under `my-trip-advisor/`.

### Backend files to create
```
backend/
  app/
    __init__.py
    main.py          # empty FastAPI() app for now
    database.py      # engine + session factory stub
    routers/         # empty __init__.py
    models/          # empty __init__.py
    schemas/         # empty __init__.py
    services/        # empty __init__.py
    dependencies/    # empty __init__.py
    core/
      __init__.py
      config.py      # pydantic-settings BaseSettings stub
  alembic/           # created by alembic init
  alembic.ini
  requirements.txt
  .env               # DATABASE_URL, JWT_SECRET, etc (gitignored)
```

**requirements.txt:**
```
fastapi>=0.111
uvicorn[standard]>=0.29
sqlmodel>=0.0.18
alembic>=1.13
pyjwt>=2.8
passlib[bcrypt]>=1.7
pydantic-settings>=2.2
python-multipart>=0.0.9
```

**Commands:**
```bash
cd backend
python -m venv .venv && source .venv/bin/activate   # or .venv\Scripts\activate on Windows
pip install -r requirements.txt
alembic init alembic
```

In `alembic/env.py`, update `target_metadata` to point at SQLModel's metadata (do this in Phase 2 once models exist).

**`app/core/config.py`:**
```python
from pydantic_settings import BaseSettings

class Settings(BaseSettings):
    database_url: str = "sqlite:///./dev.db"
    jwt_secret: str = "changeme"
    jwt_expires_days: int = 7
    port: int = 8000
    cors_origins: str = "http://localhost:5173"

    class Config:
        env_file = ".env"

settings = Settings()
```

**`app/database.py`:**
```python
from sqlmodel import create_engine, Session
from app.core.config import settings

engine = create_engine(settings.database_url, connect_args={"check_same_thread": False})

def get_session():
    with Session(engine) as session:
        yield session
```

### Frontend files to create
```bash
cd ..
npm create vite@latest frontend -- --template react-ts
cd frontend
npm install
npm install axios @tanstack/react-query react-router-dom react-hook-form zod @hookform/resolvers jspdf html2canvas tailwindcss @tailwindcss/vite
npx tailwindcss init
```

**`frontend/vite.config.ts`** — add proxy so `/api` calls forward to FastAPI:
```ts
server: {
  proxy: {
    '/api': 'http://localhost:8000'
  }
}
```

**`frontend/src/main.tsx`** — wrap app in `QueryClientProvider` (stub for now).

### Verify
- `cd backend && uvicorn app.main:app --reload` starts without error; `http://localhost:8000/docs` shows empty OpenAPI page.
- `cd frontend && npm run dev` starts Vite on port 5173 without error.

---

## Phase 2 — Backend: Data Models + Migrations

### Files to create / modify
- `app/models/user.py`
- `app/models/trip.py`
- `app/models/activity.py`
- `app/models/__init__.py` — re-export all models
- `alembic/env.py` — wire SQLModel metadata

### `app/models/user.py`
```python
from sqlmodel import SQLModel, Field
from uuid import uuid4
from datetime import datetime

class User(SQLModel, table=True):
    id: str = Field(default_factory=lambda: str(uuid4()), primary_key=True)
    username: str = Field(unique=True, index=True)
    password_hash: str
    created_at: datetime = Field(default_factory=datetime.utcnow)
```

### `app/models/trip.py`
```python
from sqlmodel import SQLModel, Field, Relationship
from uuid import uuid4
from datetime import datetime, date
from typing import List, TYPE_CHECKING

if TYPE_CHECKING:
    from app.models.activity import Activity

class Trip(SQLModel, table=True):
    id: str = Field(default_factory=lambda: str(uuid4()), primary_key=True)
    user_id: str = Field(foreign_key="user.id", index=True)
    destination: str
    start_date: date
    end_date: date
    trip_type: str
    created_at: datetime = Field(default_factory=datetime.utcnow)
    activities: List["Activity"] = Relationship(
        back_populates="trip",
        sa_relationship_kwargs={"cascade": "all, delete-orphan"}
    )
```

### `app/models/activity.py`
```python
from sqlmodel import SQLModel, Field, Relationship
from uuid import uuid4
from datetime import datetime
from typing import Optional, TYPE_CHECKING

if TYPE_CHECKING:
    from app.models.trip import Trip

class Activity(SQLModel, table=True):
    id: str = Field(default_factory=lambda: str(uuid4()), primary_key=True)
    trip_id: str = Field(foreign_key="trip.id", index=True)
    day_index: int
    text: str
    created_at: datetime = Field(default_factory=datetime.utcnow)
    updated_at: datetime = Field(default_factory=datetime.utcnow)
    trip: Optional["Trip"] = Relationship(back_populates="activities")
```

### `alembic/env.py` (key change)
Import all models before `target_metadata`:
```python
from sqlmodel import SQLModel
import app.models  # noqa — ensures all models are registered
target_metadata = SQLModel.metadata
```

Also set `sqlalchemy.url` to read from config:
```python
from app.core.config import settings
config.set_main_option("sqlalchemy.url", settings.database_url)
```

### Commands
```bash
alembic revision --autogenerate -m "initial tables"
alembic upgrade head
```

### Verify
```bash
python -c "import sqlite3; c=sqlite3.connect('dev.db'); print(c.execute(\"SELECT name FROM sqlite_master WHERE type='table'\").fetchall())"
```
Should print `[('user',), ('trip',), ('activity',), ('alembic_version',)]`.

---

## Phase 3 — Backend: Auth Endpoints

### Files to create / modify
- `app/core/security.py`
- `app/schemas/auth.py`
- `app/services/auth_service.py`
- `app/routers/auth.py`
- `app/main.py` — add CORS, include auth router

### `app/core/security.py`
```python
import jwt
from datetime import datetime, timedelta
from passlib.context import CryptContext
from app.core.config import settings

pwd_context = CryptContext(schemes=["bcrypt"], deprecated="auto")

def hash_password(plain: str) -> str:
    return pwd_context.hash(plain)

def verify_password(plain: str, hashed: str) -> bool:
    return pwd_context.verify(plain, hashed)

def create_token(user_id: str, username: str) -> str:
    expire = datetime.utcnow() + timedelta(days=settings.jwt_expires_days)
    return jwt.encode(
        {"sub": user_id, "username": username, "exp": expire},
        settings.jwt_secret,
        algorithm="HS256"
    )

def decode_token(token: str) -> dict:
    return jwt.decode(token, settings.jwt_secret, algorithms=["HS256"])
```

### `app/schemas/auth.py`
```python
from pydantic import BaseModel, Field, ConfigDict
from pydantic.alias_generators import to_camel

class CamelModel(BaseModel):
    model_config = ConfigDict(alias_generator=to_camel, populate_by_name=True)

class SignupRequest(CamelModel):
    username: str = Field(min_length=3, max_length=30, pattern=r"^[a-zA-Z0-9_]+$")
    password: str = Field(min_length=8)

class LoginRequest(CamelModel):
    username: str
    password: str

class UserOut(CamelModel):
    id: str
    username: str

class AuthResponse(CamelModel):
    token: str
    user: UserOut
```

> Note: `CamelModel` is the shared base for all schemas in the project — import it from `app/schemas/auth.py` or move it to `app/schemas/base.py`.

### `app/services/auth_service.py`
```python
from sqlmodel import Session, select
from fastapi import HTTPException
from app.models.user import User
from app.core.security import hash_password, verify_password, create_token
from app.schemas.auth import SignupRequest, LoginRequest, AuthResponse, UserOut

def signup(req: SignupRequest, db: Session) -> AuthResponse:
    existing = db.exec(select(User).where(User.username == req.username)).first()
    if existing:
        raise HTTPException(status_code=409, detail={"code": "USERNAME_TAKEN", "message": "Username already taken"})
    user = User(username=req.username, password_hash=hash_password(req.password))
    db.add(user); db.commit(); db.refresh(user)
    token = create_token(user.id, user.username)
    return AuthResponse(token=token, user=UserOut(id=user.id, username=user.username))

def login(req: LoginRequest, db: Session) -> AuthResponse:
    user = db.exec(select(User).where(User.username == req.username)).first()
    if not user or not verify_password(req.password, user.password_hash):
        raise HTTPException(status_code=401, detail={"code": "INVALID_CREDENTIALS", "message": "Invalid username or password"})
    token = create_token(user.id, user.username)
    return AuthResponse(token=token, user=UserOut(id=user.id, username=user.username))
```

### `app/routers/auth.py`
```python
from fastapi import APIRouter, Depends
from sqlmodel import Session
from app.database import get_session
from app.schemas.auth import SignupRequest, LoginRequest, AuthResponse
from app.services import auth_service

router = APIRouter(prefix="/api/v1/auth", tags=["auth"])

@router.post("/signup", response_model=AuthResponse, status_code=201)
def signup(req: SignupRequest, db: Session = Depends(get_session)):
    return auth_service.signup(req, db)

@router.post("/login", response_model=AuthResponse)
def login(req: LoginRequest, db: Session = Depends(get_session)):
    return auth_service.login(req, db)
```

### `app/main.py`
```python
from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware
from app.core.config import settings
from app.routers import auth

app = FastAPI()

app.add_middleware(
    CORSMiddleware,
    allow_origins=settings.cors_origins.split(","),
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

app.include_router(auth.router)
```

### Verify
`POST http://localhost:8000/api/v1/auth/signup` with `{"username":"alice","password":"password123"}` returns `201` with `token` and `user.id`.
`POST /auth/login` with wrong password returns `401`.
`POST /auth/signup` with same username a second time returns `409`.

---

## Phase 4 — Backend: Auth Dependency

### Files to create / modify
- `app/dependencies/auth.py`

### `app/dependencies/auth.py`
```python
from fastapi import Depends, HTTPException
from fastapi.security import HTTPBearer, HTTPAuthorizationCredentials
from sqlmodel import Session, select
from app.database import get_session
from app.models.user import User
from app.core.security import decode_token
import jwt

bearer = HTTPBearer()

def get_current_user(
    credentials: HTTPAuthorizationCredentials = Depends(bearer),
    db: Session = Depends(get_session)
) -> User:
    try:
        payload = decode_token(credentials.credentials)
    except jwt.ExpiredSignatureError:
        raise HTTPException(status_code=401, detail={"code": "UNAUTHORIZED", "message": "Token expired"})
    except jwt.InvalidTokenError:
        raise HTTPException(status_code=401, detail={"code": "UNAUTHORIZED", "message": "Invalid token"})
    user = db.exec(select(User).where(User.id == payload["sub"])).first()
    if not user:
        raise HTTPException(status_code=401, detail={"code": "UNAUTHORIZED", "message": "User not found"})
    return user
```

### Verify
Call `GET /api/v1/trips` (not yet implemented) without a token — expect `403` from HTTPBearer (will become `401` once the trips router uses `get_current_user`). Alternatively write a quick test endpoint in main.py, confirm 401, then remove it.

---

## Phase 5 — Backend: Trips Endpoints

### Files to create / modify
- `app/schemas/trip.py`
- `app/services/trip_service.py`
- `app/routers/trips.py`
- `app/main.py` — include trips router

### `app/schemas/trip.py`
```python
from pydantic import Field
from datetime import date, datetime
from typing import List
from app.schemas.auth import CamelModel  # shared base

VALID_TRIP_TYPES = ("solo", "couple", "family", "group_of_friends")

class TripCreate(CamelModel):
    destination: str = Field(min_length=1, max_length=100)
    start_date: date
    end_date: date
    trip_type: str

    def model_post_init(self, __context):
        if self.end_date < self.start_date:
            raise ValueError("end_date must be >= start_date")
        if self.trip_type not in VALID_TRIP_TYPES:
            raise ValueError(f"trip_type must be one of {VALID_TRIP_TYPES}")

class ActivityOut(CamelModel):
    id: str
    trip_id: str
    day_index: int
    text: str
    created_at: datetime
    updated_at: datetime

class TripOut(CamelModel):
    id: str
    destination: str
    start_date: date
    end_date: date
    trip_type: str
    created_at: datetime

class TripDetailOut(TripOut):
    activities: List[ActivityOut] = []
```

### `app/services/trip_service.py`
```python
from sqlmodel import Session, select
from fastapi import HTTPException
from app.models.trip import Trip
from app.models.activity import Activity
from app.models.user import User
from app.schemas.trip import TripCreate, TripOut, TripDetailOut, ActivityOut

def list_trips(user: User, db: Session):
    trips = db.exec(select(Trip).where(Trip.user_id == user.id).order_by(Trip.created_at.desc())).all()
    return [TripOut.model_validate(t, from_attributes=True) for t in trips]

def create_trip(req: TripCreate, user: User, db: Session) -> TripOut:
    trip = Trip(user_id=user.id, **req.model_dump())
    db.add(trip); db.commit(); db.refresh(trip)
    return TripOut.model_validate(trip, from_attributes=True)

def get_trip(trip_id: str, user: User, db: Session) -> TripDetailOut:
    trip = db.exec(select(Trip).where(Trip.id == trip_id, Trip.user_id == user.id)).first()
    if not trip:
        raise HTTPException(status_code=404, detail={"code": "RESOURCE_NOT_FOUND"})
    activities = db.exec(
        select(Activity).where(Activity.trip_id == trip_id)
        .order_by(Activity.day_index, Activity.created_at)
    ).all()
    out = TripDetailOut.model_validate(trip, from_attributes=True)
    out.activities = [ActivityOut.model_validate(a, from_attributes=True) for a in activities]
    return out

def delete_trip(trip_id: str, user: User, db: Session):
    trip = db.exec(select(Trip).where(Trip.id == trip_id, Trip.user_id == user.id)).first()
    if not trip:
        raise HTTPException(status_code=404, detail={"code": "RESOURCE_NOT_FOUND"})
    db.delete(trip); db.commit()
```

### `app/routers/trips.py`
```python
from fastapi import APIRouter, Depends
from sqlmodel import Session
from app.database import get_session
from app.dependencies.auth import get_current_user
from app.models.user import User
from app.schemas.trip import TripCreate, TripOut, TripDetailOut
from app.services import trip_service
from typing import List

router = APIRouter(prefix="/api/v1/trips", tags=["trips"])

@router.get("", response_model=List[TripOut])
def list_trips(user: User = Depends(get_current_user), db: Session = Depends(get_session)):
    return trip_service.list_trips(user, db)

@router.post("", response_model=TripOut, status_code=201)
def create_trip(req: TripCreate, user: User = Depends(get_current_user), db: Session = Depends(get_session)):
    return trip_service.create_trip(req, user, db)

@router.get("/{trip_id}", response_model=TripDetailOut)
def get_trip(trip_id: str, user: User = Depends(get_current_user), db: Session = Depends(get_session)):
    return trip_service.get_trip(trip_id, user, db)

@router.delete("/{trip_id}", status_code=204)
def delete_trip(trip_id: str, user: User = Depends(get_current_user), db: Session = Depends(get_session)):
    trip_service.delete_trip(trip_id, user, db)
```

Add `app.include_router(trips.router)` to `main.py`.

### Verify
- Authenticated `GET /api/v1/trips` returns `[]`.
- `POST /api/v1/trips` with valid body returns `201` with `id`.
- `GET /api/v1/trips/{id}` returns trip with `activities: []`.
- `DELETE /api/v1/trips/{id}` returns `204`.
- All above with wrong user token return `404`.

---

## Phase 6 — Backend: Activities Endpoints

### Files to create / modify
- `app/schemas/activity.py`
- `app/services/activity_service.py`
- `app/routers/activities.py`
- `app/main.py` — include activities router

### `app/schemas/activity.py`
```python
from pydantic import Field
from app.schemas.auth import CamelModel

class ActivityCreate(CamelModel):
    day_index: int = Field(ge=1)
    text: str = Field(min_length=1, max_length=300)

class ActivityUpdate(CamelModel):
    text: str = Field(min_length=1, max_length=300)
```

### `app/services/activity_service.py`
```python
from datetime import datetime
from sqlmodel import Session, select
from fastapi import HTTPException
from app.models.trip import Trip
from app.models.activity import Activity
from app.models.user import User
from app.schemas.activity import ActivityCreate, ActivityUpdate
from app.schemas.trip import ActivityOut

def _get_owned_trip(trip_id: str, user: User, db: Session) -> Trip:
    trip = db.exec(select(Trip).where(Trip.id == trip_id, Trip.user_id == user.id)).first()
    if not trip:
        raise HTTPException(status_code=404, detail={"code": "RESOURCE_NOT_FOUND"})
    return trip

def add_activity(trip_id: str, req: ActivityCreate, user: User, db: Session) -> ActivityOut:
    trip = _get_owned_trip(trip_id, user, db)
    max_day = (trip.end_date - trip.start_date).days + 1
    if req.day_index > max_day:
        raise HTTPException(status_code=400, detail={"code": "INVALID_DAY_INDEX"})
    activity = Activity(trip_id=trip_id, day_index=req.day_index, text=req.text)
    db.add(activity); db.commit(); db.refresh(activity)
    return ActivityOut.model_validate(activity, from_attributes=True)

def update_activity(trip_id: str, activity_id: str, req: ActivityUpdate, user: User, db: Session) -> ActivityOut:
    _get_owned_trip(trip_id, user, db)
    activity = db.exec(select(Activity).where(Activity.id == activity_id, Activity.trip_id == trip_id)).first()
    if not activity:
        raise HTTPException(status_code=404, detail={"code": "RESOURCE_NOT_FOUND"})
    activity.text = req.text
    activity.updated_at = datetime.utcnow()
    db.add(activity); db.commit(); db.refresh(activity)
    return ActivityOut.model_validate(activity, from_attributes=True)

def delete_activity(trip_id: str, activity_id: str, user: User, db: Session):
    _get_owned_trip(trip_id, user, db)
    activity = db.exec(select(Activity).where(Activity.id == activity_id, Activity.trip_id == trip_id)).first()
    if not activity:
        raise HTTPException(status_code=404, detail={"code": "RESOURCE_NOT_FOUND"})
    db.delete(activity); db.commit()
```

### `app/routers/activities.py`
```python
from fastapi import APIRouter, Depends
from sqlmodel import Session
from app.database import get_session
from app.dependencies.auth import get_current_user
from app.models.user import User
from app.schemas.activity import ActivityCreate, ActivityUpdate
from app.schemas.trip import ActivityOut
from app.services import activity_service

router = APIRouter(prefix="/api/v1/trips/{trip_id}/activities", tags=["activities"])

@router.post("", response_model=ActivityOut, status_code=201)
def add_activity(trip_id: str, req: ActivityCreate, user: User = Depends(get_current_user), db: Session = Depends(get_session)):
    return activity_service.add_activity(trip_id, req, user, db)

@router.put("/{activity_id}", response_model=ActivityOut)
def update_activity(trip_id: str, activity_id: str, req: ActivityUpdate, user: User = Depends(get_current_user), db: Session = Depends(get_session)):
    return activity_service.update_activity(trip_id, activity_id, req, user, db)

@router.delete("/{activity_id}", status_code=204)
def delete_activity(trip_id: str, activity_id: str, user: User = Depends(get_current_user), db: Session = Depends(get_session)):
    activity_service.delete_activity(trip_id, activity_id, user, db)
```

Add `app.include_router(activities.router)` to `main.py`.

### Verify
- `POST /api/v1/trips/{id}/activities` with `{"dayIndex":1,"text":"Visit the Eiffel Tower"}` returns `201`.
- `GET /api/v1/trips/{id}` now shows the activity nested in `activities`.
- `PUT` updates text; `DELETE` removes activity; both return correct status codes.
- `dayIndex` beyond trip length returns `400 INVALID_DAY_INDEX`.

---

## Phase 7 — Frontend: Core Infrastructure

### Files to create / modify
```
src/
  lib/
    axios.ts          # configured Axios instance
  contexts/
    AuthContext.tsx   # AuthProvider + useAuth hook
  components/
    ProtectedRoute.tsx
    AppShell.tsx
  router.tsx          # createBrowserRouter with all routes
  main.tsx            # QueryClientProvider + RouterProvider
```

### `src/lib/axios.ts`
```ts
import axios from 'axios'

const api = axios.create({ baseURL: '/api/v1' })

// Attach JWT to every request
api.interceptors.request.use(config => {
  const token = localStorage.getItem('token')
  if (token) config.headers.Authorization = `Bearer ${token}`
  return config
})

// On 401: clear session, redirect to /login?expired=1
api.interceptors.response.use(
  res => res,
  err => {
    if (err.response?.status === 401) {
      localStorage.removeItem('token')
      localStorage.removeItem('user')
      window.location.href = '/login?expired=1'
    }
    return Promise.reject(err)
  }
)

export default api
```

### `src/contexts/AuthContext.tsx`
```tsx
// Stores { id, username } from login/signup response
// Exposes: user, login(token, user), logout()
// Reads from localStorage on mount so session survives refresh
```
Key: `login()` saves token + user to localStorage and updates state; `logout()` clears both and navigates to `/login`.

### `src/components/ProtectedRoute.tsx`
```tsx
// Reads useAuth().user; if null renders <Navigate to="/login" replace />
// Otherwise renders <Outlet />
```

### `src/components/AppShell.tsx`
```tsx
// Top nav: "My Trip Planner" brand (left)
// Right: <Link to="/trips">My Trips</Link>, username span, Logout button
// Logout calls useAuth().logout()
// Wraps children in a <main> with gray-50 background
```

### `src/router.tsx`
```tsx
createBrowserRouter([
  { path: '/', element: <RootRedirect /> },   // checks auth, redirects
  { path: '/login', element: <LoginPage /> },
  { path: '/signup', element: <SignupPage /> },
  {
    element: <ProtectedRoute />,
    children: [
      { path: '/trips', element: <TripsPage /> },
      { path: '/trips/new', element: <CreateTripPage /> },
      { path: '/trips/:tripId', element: <TripPage /> },
    ]
  }
])
```

### Verify
- `/` redirects to `/login` when no token in localStorage.
- Manually set `localStorage.setItem('token','fake')` and visit `/` — redirects to `/trips` (which shows a loading state or 401).
- AppShell renders with nav items visible on any protected route.

---

## Phase 8 — Frontend: Shared UI Components

### Files to create
```
src/components/ui/
  Button.tsx        # primary | secondary variant prop; loading spinner (disabled when loading)
  TextInput.tsx     # label, name, error props; renders <label> + <input> + error span
  DateInput.tsx     # same as TextInput but type="date"
  PageHeading.tsx   # renders <h1> with consistent style
  ErrorBanner.tsx   # full-width red/orange bar; accepts message string; null → renders nothing
```

All components use Tailwind classes. No logic — pure presentational.

### Verify
Render each component in isolation via a temporary test route or Storybook-style page. Confirm keyboard accessibility (Tab reaches inputs; Enter triggers buttons).

---

## Phase 9 — Frontend: Auth Pages

### Files to create
```
src/
  schemas/
    auth.ts           # Zod schemas: loginSchema, signupSchema
  hooks/
    useLogin.ts       # useMutation wrapping POST /auth/login
    useSignup.ts      # useMutation wrapping POST /auth/signup
  components/
    LoginForm.tsx
    SignupForm.tsx
  pages/
    LoginPage.tsx     # reads ?expired=1 param, renders warning banner if present
    SignupPage.tsx
```

### `src/schemas/auth.ts`
```ts
import { z } from 'zod'

export const loginSchema = z.object({
  username: z.string().min(1, 'Required'),
  password: z.string().min(1, 'Required'),
})

export const signupSchema = z.object({
  username: z.string()
    .min(3, 'Min 3 characters')
    .max(30, 'Max 30 characters')
    .regex(/^[a-zA-Z0-9_]+$/, 'Letters, digits, and underscores only'),
  password: z.string().min(8, 'Min 8 characters'),
  confirmPassword: z.string(),
}).refine(d => d.password === d.confirmPassword, {
  message: 'Passwords do not match',
  path: ['confirmPassword'],
})
```

### `src/hooks/useLogin.ts`
```ts
// useMutation calling api.post('/auth/login', data)
// onSuccess: call auth.login(token, user) then navigate('/trips')
// Returns { mutate, isPending, error }
```

### `src/hooks/useSignup.ts`
```ts
// Same pattern; onSuccess navigates to /trips
// On 409: surface error as ErrorBanner message
```

### `LoginPage.tsx`
```tsx
// useSearchParams() → if params.get('expired') === '1', show warning banner
// Renders LoginForm inside centered card
```

### Verify
- Sign up with valid credentials → lands on `/trips`.
- Sign up with duplicate username → ErrorBanner shows.
- Login with wrong password → ErrorBanner shows.
- Visit `/login?expired=1` → yellow warning banner visible.

---

## Phase 10 — Frontend: Trips List + Create

### Files to create
```
src/
  hooks/
    useTrips.ts         # useQuery GET /trips
    useCreateTrip.ts    # useMutation POST /trips; onSuccess navigate to /trips/:id
    useDeleteTrip.ts    # useMutation DELETE /trips/:id; onSuccess invalidateQueries(['trips'])
  components/
    TripCard.tsx
    TripList.tsx
    TripTypeSelector.tsx
    TripForm.tsx
  pages/
    TripsPage.tsx
    CreateTripPage.tsx
```

### tripType mapping (defined once, imported everywhere)
```ts
// src/lib/tripTypes.ts
export const TRIP_TYPE_OPTIONS = [
  { label: 'Solo',             value: 'solo' },
  { label: 'Couple',           value: 'couple' },
  { label: 'Family',           value: 'family' },
  { label: 'Group of Friends', value: 'group_of_friends' },
] as const

export type TripTypeValue = typeof TRIP_TYPE_OPTIONS[number]['value']

export function tripTypeLabel(value: string): string {
  return TRIP_TYPE_OPTIONS.find(o => o.value === value)?.label ?? value
}
```

### `TripCard.tsx`
- Shows destination, date range ("15 June 2024 – 22 June 2024" via `Intl.DateTimeFormat`), `tripTypeLabel(tripType)` badge.
- Delete button: `onClick` sets local `confirming` state; shows "Are you sure? [Confirm] [Cancel]" inline; Confirm calls `useDeleteTrip`.

### `TripTypeSelector.tsx`
- Renders `TRIP_TYPE_OPTIONS` as button group; selected value highlighted blue; calls `onChange(value)`.

### `TripForm.tsx`
- React Hook Form + `tripFormSchema` (Zod: destination max 100, startDate required, endDate ≥ startDate, tripType required).
- Uses `TripTypeSelector` for tripType field.
- Submit calls `useCreateTrip`.

### `TripsPage.tsx`
- Calls `useTrips()`; shows spinner while loading.
- Renders "My Trips" heading + "+ New Trip" button (always visible).
- If `trips.length === 0`: empty state. Else: 2-column grid of `TripCard`.

### Verify
- Create a trip → redirected to itinerary page.
- Return to `/trips` → card visible with correct badge label.
- Delete trip → confirm prompt appears; on confirm trip removed without reload.

---

## Phase 11 — Frontend: Itinerary + Activities

### Files to create
```
src/
  hooks/
    useTripDetail.ts     # useQuery GET /trips/:tripId
    useAddActivity.ts    # useMutation POST; onSuccess invalidate trip detail
    useUpdateActivity.ts # useMutation PUT
    useDeleteActivity.ts # useMutation DELETE
  components/
    TripHeader.tsx
    ActivityItem.tsx
    ActivityInput.tsx
    DayPanel.tsx
    ItineraryView.tsx
  pages/
    TripPage.tsx
```

### `TripHeader.tsx`
Displays `trip.destination` as `<h1>`, date range string, and `tripTypeLabel(trip.tripType)` badge.

### `ActivityItem.tsx`
- Local state: `editing: boolean`, `editText: string`, `editError: string | null`.
- Read mode: text row + Edit + Delete buttons.
- Edit mode: `<input>` pre-filled with `editText`, Save + Cancel buttons below.
  - Save: Zod validates `editText` (non-empty, max 300); if invalid sets `editError`; if valid calls `useUpdateActivity`; on error from server sets `editError` and keeps field open.
  - Cancel: resets `editing` to false, restores original text.
- Delete: local `confirming` state → "Are you sure? Confirm / Cancel" → calls `useDeleteActivity`.

### `DayPanel.tsx`
- Props: `tripId`, `dayIndex`, `date` (derived from startDate + dayIndex), `activities`.
- Renders heading "Day N – [weekday, DD Month YYYY]" via `Intl.DateTimeFormat('en-GB', { weekday:'long', day:'numeric', month:'long', year:'numeric' })`.
- Maps `activities` to `ActivityItem` components.
- Renders `ActivityInput` at the bottom.

### `ItineraryView.tsx`
- Derives day array from `startDate` and `endDate`: `eachDayOfInterval` or manual loop.
- Renders `TripHeader` + `ExportButton` outside `#itinerary-print-area`.
- Wraps `<div id="itinerary-print-area">` around `TripHeader` (duplicated inside for PDF) + all `DayPanel`s.

> Note: `TripHeader` renders twice — once above `ExportButton` for the screen, once inside `#itinerary-print-area` for the PDF. Or place header inside print area only and use CSS to position ExportButton outside it.

### `ActivityInput.tsx`
- Controlled `<input>` + "Add" button.
- Local Zod validation on submit (non-empty, max 300).
- Calls `useAddActivity({ tripId, dayIndex, text })`.
- Clears field on success.

### Verify
- Open trip → see correct number of DayPanels.
- Add activity to Day 1 → appears immediately.
- Edit activity → inline field opens pre-filled; save updates text.
- Delete activity → confirm then removed.
- Edit with 301-char text → inline error shown, field stays open.

---

## Phase 12 — PDF Export

### Files to create / modify
- `src/components/ExportButton.tsx`

### `ExportButton.tsx`
```tsx
import html2canvas from 'html2canvas'
import jsPDF from 'jspdf'

async function handleExport(trip: { destination: string; startDate: string }) {
  const el = document.getElementById('itinerary-print-area')
  if (!el) return

  const canvas = await html2canvas(el, { scale: 2, useCORS: true })
  const imgData = canvas.toDataURL('image/png')
  const pdf = new jsPDF({ orientation: 'portrait', unit: 'px', format: [canvas.width / 2, canvas.height / 2] })
  pdf.addImage(imgData, 'PNG', 0, 0, canvas.width / 2, canvas.height / 2)

  // Sanitise filename
  const dest = trip.destination.replace(/\s+/g, '-').replace(/[^a-zA-Z0-9-]/g, '')
  pdf.save(`itinerary-${trip.startDate}-${dest}.pdf`)
}
```

Render as a green "Export PDF" button; show spinner while `isPending` local state is true.

### Verify
- Click Export on a trip with 3 days → PDF downloads.
- Open PDF: nav bar and Export button not visible; TripHeader and day panels visible.
- Filename matches `itinerary-{startDate}-{destination}.pdf` with special chars removed.

---

## Phase 13 — Polish + Responsive

### What to do
1. **Tailwind responsive classes:** `TripList` card grid: `grid-cols-1 md:grid-cols-2`. Ensure itinerary usable at 390 px.
2. **Loading spinners:** Add `<Spinner />` (animated Tailwind border-spin div) for trip list fetch and trip detail fetch.
3. **Full acceptance criteria pass:** Walk through every AC item in `frontend-spec.md` manually in the browser.
4. **End-to-end smoke test:**
   - Sign up as a new user.
   - Create a trip (Paris, 15 June – 17 June 2024, Couple).
   - Add activities to Day 1 and Day 2.
   - Edit one activity; delete another.
   - Export PDF; verify filename and contents.
   - Log out; verify redirect to `/login` with no message.
   - Log back in; verify trip still listed.
5. **Error path test:** Disconnect the backend; trigger a non-401 API error; confirm `ErrorBanner` appears.

### Verify
All 43 acceptance criteria in `frontend-spec.md` pass.

---

## Build Order Rationale

**Why backend before frontend:**
The frontend is entirely driven by the API contract. Building the backend first means the frontend can make real API calls from the start instead of mocking responses. Mocks diverge from reality — the backend-first approach means integration issues surface during feature development, not after.

**Why core infrastructure before features (Phases 7–8 before 9–13):**
Every feature page depends on the Axios instance (auth headers, 401 redirect), AuthContext (who is logged in), ProtectedRoute (access control), and AppShell (nav). Building these first means each feature page can be wired up immediately as it is built, without needing to retrofit them later. Shared UI components (Phase 8) are the building blocks of every form and page — building them once prevents duplication and ensures visual consistency throughout.
