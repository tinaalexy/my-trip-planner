# API Contract Specification

> Connects the frontend (React + TypeScript) and backend (Python + FastAPI). Both sides must treat this file as the source of truth for field names, types, and status codes.

## Base URL & Versioning

All endpoints are prefixed with `/api/v1`.

Example: `POST /api/v1/auth/signup`

No breaking changes within v1. A new major version (`/api/v2`) would be introduced for breaking changes.

## Authentication

Protected endpoints require an `Authorization` header:

```
Authorization: Bearer <token>
```

The token is a JWT returned by `/auth/signup` or `/auth/login`. It expires after 7 days. The frontend stores it in `localStorage` and attaches it via an Axios request interceptor. A 401 response on any protected endpoint means the token is missing, invalid, or expired — the frontend clears the session and redirects to `/login?expired=1`, which displays "Your session has expired, please log in again" above the login form.

## Common Conventions

| Convention | Value |
|------------|-------|
| Field naming | `camelCase` for all request and response JSON fields |
| Date fields | `YYYY-MM-DD` string (e.g. `"2024-06-15"`) |
| Datetime fields | ISO 8601 UTC string (e.g. `"2024-06-15T10:30:00Z"`) |
| ID fields | UUID v4 string |
| `tripType` wire values | `"solo"` · `"couple"` · `"family"` · `"group_of_friends"` — the frontend maps these to/from display labels ("Solo", "Couple", "Family", "Group of Friends") |
| Empty response body | 204 No Content (no JSON) |

## Error Response Format

All error responses use this envelope:

```json
{
  "error": {
    "code": "SNAKE_CASE_CODE",
    "message": "Human-readable description",
    "statusCode": 404
  }
}
```

Common error codes:

| Code | Status | Meaning |
|------|--------|---------|
| `VALIDATION_ERROR` | 422 | Request body failed schema validation; `details` array added with field-level messages |
| `INVALID_CREDENTIALS` | 401 | Username or password is wrong |
| `UNAUTHORIZED` | 401 | Missing, invalid, or expired Bearer token |
| `USERNAME_TAKEN` | 409 | Signup attempted with an already-registered username |
| `RESOURCE_NOT_FOUND` | 404 | Resource does not exist or belongs to another user |
| `INVALID_DAY_INDEX` | 400 | `dayIndex` is outside the trip's date range |

---

## Endpoints

### Auth

#### `POST /api/v1/auth/signup`

**Description:** Create a new account and return a JWT.

**Auth required:** No

**Request body:**
```json
{
  "username": "string — 3–30 chars, letters/digits/underscores only",
  "password": "string — min 8 characters"
}
```

**Response `201 Created`:**
```json
{
  "token": "string — signed JWT",
  "user": {
    "id": "uuid",
    "username": "string"
  }
}
```

**Error codes:**
| Status | Code | Condition |
|--------|------|-----------|
| 422 | `VALIDATION_ERROR` | `username` or `password` fails schema rules |
| 409 | `USERNAME_TAKEN` | Username is already registered |

---

#### `POST /api/v1/auth/login`

**Description:** Authenticate with username and password and return a JWT.

**Auth required:** No

**Request body:**
```json
{
  "username": "string",
  "password": "string"
}
```

**Response `200 OK`:**
```json
{
  "token": "string — signed JWT",
  "user": {
    "id": "uuid",
    "username": "string"
  }
}
```

**Error codes:**
| Status | Code | Condition |
|--------|------|-----------|
| 422 | `VALIDATION_ERROR` | Either field is empty |
| 401 | `INVALID_CREDENTIALS` | Username not found or password does not match |

---

### Trips

#### `GET /api/v1/trips`

**Description:** Return all trips belonging to the authenticated user, ordered by `createdAt` descending.

**Auth required:** Yes

**Response `200 OK`:**
```json
[
  {
    "id": "uuid",
    "destination": "string",
    "startDate": "YYYY-MM-DD",
    "endDate": "YYYY-MM-DD",
    "tripType": "solo | couple | family | group_of_friends",
    "createdAt": "ISO 8601 datetime"
  }
]
```

Returns an empty array `[]` when the user has no trips.

---

#### `POST /api/v1/trips`

**Description:** Create a new trip for the authenticated user.

**Auth required:** Yes

**Request body:**
```json
{
  "destination": "string — non-empty, max 100 characters",
  "startDate": "YYYY-MM-DD",
  "endDate": "YYYY-MM-DD — must be ≥ startDate",
  "tripType": "solo | couple | family | group_of_friends"
}
```

**Response `201 Created`:**
```json
{
  "id": "uuid",
  "destination": "string",
  "startDate": "YYYY-MM-DD",
  "endDate": "YYYY-MM-DD",
  "tripType": "string",
  "createdAt": "ISO 8601 datetime"
}
```

**Error codes:**
| Status | Code | Condition |
|--------|------|-----------|
| 422 | `VALIDATION_ERROR` | Any field is missing, empty, or `endDate` < `startDate` |

---

#### `GET /api/v1/trips/:tripId`

**Description:** Return a single trip with all of its activities, ordered by `dayIndex` then `createdAt` ascending.

**Auth required:** Yes

**Path params:** `tripId` — UUID of the trip

**Response `200 OK`:**
```json
{
  "id": "uuid",
  "destination": "string",
  "startDate": "YYYY-MM-DD",
  "endDate": "YYYY-MM-DD",
  "tripType": "string",
  "createdAt": "ISO 8601 datetime",
  "activities": [
    {
      "id": "uuid",
      "dayIndex": 1,
      "text": "string",
      "createdAt": "ISO 8601 datetime",
      "updatedAt": "ISO 8601 datetime"
    }
  ]
}
```

`activities` is an empty array when no activities have been added yet.

**Error codes:**
| Status | Code | Condition |
|--------|------|-----------|
| 404 | `RESOURCE_NOT_FOUND` | Trip does not exist or belongs to another user |

---

#### `DELETE /api/v1/trips/:tripId`

**Description:** Permanently delete a trip and all its activities.

**Auth required:** Yes

**Path params:** `tripId` — UUID of the trip

**Response `204 No Content`**

**Error codes:**
| Status | Code | Condition |
|--------|------|-----------|
| 404 | `RESOURCE_NOT_FOUND` | Trip does not exist or belongs to another user |

---

### Activities

#### `POST /api/v1/trips/:tripId/activities`

**Description:** Add a new activity to a specific day of a trip.

**Auth required:** Yes

**Path params:** `tripId` — UUID of the parent trip

**Request body:**
```json
{
  "dayIndex": "integer — 1-based; 1 = startDate, 2 = startDate + 1 day, etc.",
  "text": "string — non-empty, max 300 characters"
}
```

**Response `201 Created`:**
```json
{
  "id": "uuid",
  "tripId": "uuid",
  "dayIndex": 1,
  "text": "string",
  "createdAt": "ISO 8601 datetime",
  "updatedAt": "ISO 8601 datetime"
}
```

**Error codes:**
| Status | Code | Condition |
|--------|------|-----------|
| 404 | `RESOURCE_NOT_FOUND` | Trip does not exist or belongs to another user |
| 422 | `VALIDATION_ERROR` | `text` is empty or exceeds 300 chars; `dayIndex` is not a positive integer |
| 400 | `INVALID_DAY_INDEX` | `dayIndex` is outside the trip's date range |

---

#### `PUT /api/v1/trips/:tripId/activities/:activityId`

**Description:** Update the text of an existing activity.

**Auth required:** Yes

**Path params:**
- `tripId` — UUID of the parent trip
- `activityId` — UUID of the activity

**Request body:**
```json
{
  "text": "string — non-empty, max 300 characters"
}
```

**Response `200 OK`:**
```json
{
  "id": "uuid",
  "tripId": "uuid",
  "dayIndex": 1,
  "text": "string",
  "createdAt": "ISO 8601 datetime",
  "updatedAt": "ISO 8601 datetime"
}
```

**Error codes:**
| Status | Code | Condition |
|--------|------|-----------|
| 404 | `RESOURCE_NOT_FOUND` | Trip or activity does not exist, or belongs to another user |
| 422 | `VALIDATION_ERROR` | `text` is empty or exceeds 300 chars |

---

#### `DELETE /api/v1/trips/:tripId/activities/:activityId`

**Description:** Permanently delete a single activity.

**Auth required:** Yes

**Path params:**
- `tripId` — UUID of the parent trip
- `activityId` — UUID of the activity

**Response `204 No Content`**

**Error codes:**
| Status | Code | Condition |
|--------|------|-----------|
| 404 | `RESOURCE_NOT_FOUND` | Trip or activity does not exist, or belongs to another user |
