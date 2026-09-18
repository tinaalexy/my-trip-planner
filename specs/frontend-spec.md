# Frontend Specification

> Derived from goal-spec.md. All decisions here serve the 5 core features: auth, trip creation, trip list, day-by-day itinerary editing, and PDF export.

## Tech Stack

| Concern | Choice | Reason |
|---------|--------|--------|
| Framework | React 18 + TypeScript | Type safety; component model fits the itinerary UI well |
| Build tool | Vite | Fast dev server; zero config for React + TS |
| Styling | Tailwind CSS | Utility-first; fast responsive layout without a design system |
| Routing | React Router v6 | Standard; `<ProtectedRoute>` pattern is straightforward |
| Server state | TanStack Query (React Query v5) | Caching, loading/error states, and mutation invalidation out of the box |
| Forms | React Hook Form + Zod | Minimal re-renders; schema-driven validation |
| PDF export | jsPDF + html2canvas | Client-side; no server dependency for PDF generation |
| HTTP client | Axios | Interceptor for attaching JWT to every request |

## Pages & Routes

| Route | Page | Purpose | Auth required |
|-------|------|---------|--------------|
| `/` | — | Redirect: authenticated → `/trips`; unauthenticated → `/login` | No |
| `/login` | Login | Username + password sign-in form | No |
| `/signup` | Sign Up | New account creation form | No |
| `/trips` | My Trips | List of the user's trips; entry point after login | Yes |
| `/trips/new` | Create Trip | Form to create a new trip | Yes |
| `/trips/:tripId` | Trip Itinerary | Day-by-day itinerary view and activity editor | Yes |

Unauthenticated users visiting any auth-required route are redirected to `/login`. After login, users are sent to `/trips`.

## Component Inventory

### Layout
- `AppShell` — top nav bar with the app name "My Trip Planner", a "My Trips" link to `/trips`, the logged-in username (read-only, from auth context), and a Logout button; wraps all authenticated pages
- `ProtectedRoute` — wrapper that checks auth state; redirects to `/login` if no valid session

### Auth
- `LoginForm` — username + password fields, submit button, link to `/signup`
- `SignupForm` — username + password + confirm-password fields, submit button, link to `/login`

### Trips
- `TripList` — renders a "New Trip" button (links to `/trips/new`) at the top of the page at all times, then either the card grid or the empty state below it
- `TripCard` — displays trip destination, date range (e.g. "15 June 2024 – 22 June 2024"), and trip type badge (display label from the mapping table below); links to `/trips/:tripId`; includes a Delete button with a confirmation prompt
- `TripForm` — controlled form for creating a new trip (destination, start/end date, trip type); includes a Cancel button that navigates back to `/trips`
- `TripTypeSelector` — button-group for the four trip types using display labels (see mapping table below)

**`tripType` display-label to API-value mapping** (used by `TripTypeSelector`, `TripCard` badge, `TripHeader`, and Zod schema):

| Display label | API value |
|--------------|-----------|
| Solo | `solo` |
| Couple | `couple` |
| Family | `family` |
| Group of Friends | `group_of_friends` |

The form submits the API value; all display surfaces render the display label.

### Itinerary
- `TripHeader` — shows the trip's destination, formatted date range (e.g. "15 June 2024 – 22 June 2024"), and trip type display label at the top of the itinerary page, above the `ExportButton`
- `ItineraryView` — renders the `TripHeader`, then the `ExportButton`, then one `DayPanel` per day in the trip's date range; wraps the `TripHeader` and all `DayPanel`s (but not the `ExportButton`) in a `<div id="itinerary-print-area">` used as the html2canvas capture target
- `DayPanel` — shows "Day N – [weekday, date]" heading (e.g. "Day 1 – Monday, 15 June 2024"), the list of activities for that day, and the `ActivityInput`; all days are always expanded (no collapse behaviour)
- `ActivityItem` — displays a single activity as a text row; includes Edit (inline text field) and Delete (icon button with confirmation) actions
- `ActivityInput` — single-line text field + "Add" button to append an activity to a day

### Export
- `ExportButton` — triggers client-side PDF generation by capturing `#itinerary-print-area` with html2canvas (nav bar, `ExportButton`, and all action buttons are outside this element and are excluded from the PDF); downloads the result as `itinerary-{startDate}-{destination}.pdf` where destination has spaces replaced with hyphens and all other non-alphanumeric characters removed (e.g. `itinerary-2024-06-15-Cte-dAzur.pdf`); PDF is single-page best-effort — no page-break handling for v1

### Common / Shared
- `Button` — primary and secondary variants, loading spinner state
- `TextInput` — labelled `<input>` with inline error message slot
- `DateInput` — date `<input type="date">` with label and error slot
- `PageHeading` — consistent `<h1>` style used across pages
- `ErrorBanner` — full-width error message bar for API-level failures

## State Management

| State | Where it lives | Why |
|-------|---------------|-----|
| Auth (user, JWT token) | React Context + `localStorage` | Must survive page refresh; shared by every authenticated component |
| Trips list | TanStack Query (`useQuery`) | Server-owned; cached and re-fetched automatically |
| Single trip + its days/activities | TanStack Query (`useQuery`) | Same as above |
| Form data | React Hook Form (local) | Form state never needs to be global |
| UI state (e.g. activity edit mode per item) | `useState` in `ActivityItem` (local) | Component-scoped; no cross-component sharing needed |

No Zustand or Redux. The auth context + TanStack Query covers all needs.

## Data Flow

1. On login, the API returns a JWT. It is stored in `localStorage` and placed in an Axios default header (`Authorization: Bearer <token>`). Note: `localStorage` is accessible to JavaScript and therefore vulnerable to XSS. This is an accepted tradeoff for the v1 scope; a production hardening step would move to `httpOnly` cookies.
2. React Context reads the token from `localStorage` on mount and exposes `{ user, login, logout }`.
3. Page-level components call custom hooks (`useTrips`, `useTripDetail`) that wrap TanStack Query `useQuery` calls.
4. Mutations (`useCreateTrip`, `useDeleteTrip`, `useAddActivity`, `useUpdateActivity`, `useDeleteActivity`) call the API and on success call `queryClient.invalidateQueries` to refresh affected queries.
5. `ProtectedRoute` reads auth context; if no token it renders `<Navigate to="/login" />`.

## Forms & Validation

### Login
| Field | Validation |
|-------|-----------|
| username | Required |
| password | Required |

### Sign Up
| Field | Validation |
|-------|-----------|
| username | Required, 3–30 characters, alphanumeric + underscore |
| password | Required, min 8 characters |
| confirmPassword | Must match `password` |

### Create Trip
| Field | Validation |
|-------|-----------|
| destination | Required, non-empty string, max 100 characters |
| startDate | Required |
| endDate | Required, must be ≥ `startDate` |
| tripType | Required; selected via `TripTypeSelector`; submitted to API as the corresponding API value (see mapping table) |

### Add Activity (per Day)
| Field | Validation |
|-------|-----------|
| text | Required, non-empty, max 300 characters |

All validation runs client-side via Zod schemas wired into React Hook Form. Errors display inline below the relevant field on blur or on submit attempt.

## Error & Loading States

| Situation | UI treatment |
|-----------|-------------|
| Fetching trip list | Spinner centred on the page |
| Fetching trip detail | Spinner centred on the page |
| Empty trip list | Illustration + "No trips yet" message + "Create your first trip" button |
| Mutation in-flight | `Button` shows a spinner; submit is disabled to prevent double-submit |
| Destructive action (delete trip / delete activity) | Inline confirmation prompt ("Are you sure?") before the mutation fires |
| Activity edit or delete mutation fails (non-401) | Inline error message shown below the affected `ActivityItem`; the edit field stays open on edit failure so the user can retry |
| API error (non-401) | `ErrorBanner` at the top of the affected page with the error message |
| 401 Unauthorised | Clear auth context and redirect to `/login?expired=1`; the Login page detects the query param and shows "Your session has expired, please log in again" above the form |
| Intentional logout | Silent redirect to `/login` with no message — this is expected behaviour |
| Form validation error | Inline red text below each invalid field |

## Responsive / Accessibility Requirements

- **Approach:** mobile-first. Base styles target small screens; `md:` breakpoints (≥ 768 px) widen layouts.
- Trip list: single column on mobile, 2-column card grid on `md:`.
- Itinerary: days stack vertically on all screen sizes; comfortable on a phone held in portrait.
- All interactive elements reachable by keyboard (Tab / Enter / Space).
- All form inputs have associated `<label>` elements.
- Colour contrast meets WCAG AA minimum (4.5:1 for body text).
- No reliance on colour alone to convey errors (icon + text used alongside colour).

## Design Tokens / Theme

Tailwind's default scale is sufficient for the 2-weekend timeline. Custom overrides:

| Token | Value | Usage |
|-------|-------|-------|
| Primary colour | `blue-600` | Primary buttons, links, active states |
| Danger colour | `red-600` | Error messages, destructive actions |
| Background | `gray-50` | Page background |
| Card surface | `white` | Trip cards, day panels |
| Border | `gray-200` | Card borders, input borders |
| Body font | System sans-serif stack (Tailwind default) | All text |

No custom font loading for v1 — keeps the page weight minimal.

## Acceptance Criteria

### Routing & Navigation

- Visiting `/` while logged in redirects to `/trips`.
- Visiting `/` while logged out redirects to `/login`.
- Visiting any auth-required route while logged out redirects to `/login`.
- After a successful login the user lands on `/trips`.
- The `AppShell` "My Trips" link navigates to `/trips` from any authenticated page.
- The `AppShell` displays the logged-in user's username on every authenticated page.
- The `AppShell` Logout button clears the session and redirects to `/login`.

### Sign Up

- Submitting with any field empty shows an inline error on the empty field(s).
- Submitting a username shorter than 3 characters or longer than 30 shows an inline error.
- Submitting a username containing characters other than letters, digits, or underscores shows an inline error.
- Submitting a password shorter than 8 characters shows an inline error.
- Submitting with `confirmPassword` not matching `password` shows an inline error on `confirmPassword`.
- A successful sign-up creates the account and navigates to `/trips`.
- If the username is already taken the API error is displayed in an `ErrorBanner`.

### Login

- Submitting with any field empty shows an inline error on the empty field(s).
- Invalid credentials show an `ErrorBanner`; no redirect occurs.
- Valid credentials clear the `ErrorBanner` (if present) and redirect to `/trips`.

### My Trips (Trip List)

- The page shows every trip belonging to the logged-in user and no trips from other users.
- A "New Trip" button linking to `/trips/new` is visible at the top of the page regardless of whether trips exist.
- Each `TripCard` displays the destination, formatted date range, and trip type display label as a badge.
- Clicking a `TripCard` (excluding the Delete button) navigates to `/trips/:tripId`.
- When the user has no trips the empty state is shown with a "Create your first trip" button that navigates to `/trips/new`.
- Clicking Delete on a `TripCard` shows an inline confirmation prompt before any deletion occurs.
- Confirming the delete removes the trip from the list without a full page reload.
- Cancelling the delete leaves the trip in the list unchanged.

### Create Trip

- Submitting with any field empty or no trip type selected shows inline errors on each invalid field.
- Submitting with `endDate` earlier than `startDate` shows an inline error on `endDate`.
- A successful submission creates the trip and navigates to its `/trips/:tripId` itinerary page.
- The Cancel button returns to `/trips` without creating a trip.

### Trip Itinerary

- The `TripHeader` shows the trip's destination, formatted date range, and trip type display label at the top of the page.
- The page renders one `DayPanel` for each calendar day from `startDate` to `endDate` inclusive.
- Each `DayPanel` heading shows the correct "Day N – [Weekday, DD Month YYYY]" label (e.g. "Day 1 – Monday, 15 June 2024"; Day 1 = `startDate`).
- All `DayPanel`s are visible and expanded on page load — none are collapsed.
- The `ExportButton` is visible above the list of days.

### Activity Management

- Submitting an empty activity input shows an inline error; no activity is added.
- Submitting an activity exceeding 300 characters shows an inline error; no activity is added.
- A successfully added activity appears at the bottom of the correct day's activity list immediately.
- Clicking Edit on an `ActivityItem` replaces the text row with an inline text field pre-filled with the current text.
- Saving the edit with an empty field or text exceeding 300 characters shows an inline error; the field stays open.
- Saving a valid edit updates the activity text in place and returns to the read-only row.
- If the save request fails (non-401 server error) an inline error is shown below the field; the field stays open so the user can retry.
- Cancelling the edit restores the original text with no change.
- Clicking Delete on an `ActivityItem` shows a confirmation prompt before any deletion occurs.
- Confirming the delete removes the activity from the day's list without a full page reload.
- Cancelling the delete leaves the activity unchanged.

### PDF Export

- Clicking `ExportButton` triggers a file download named `itinerary-{startDate}-{destination}.pdf` with spaces replaced by hyphens and all other non-alphanumeric characters removed (e.g. `itinerary-2024-06-15-Paris.pdf`).
- The downloaded PDF contains the trip header (destination, date range, trip type) and all days with their activities.
- The PDF does not contain the nav bar, the `ExportButton`, or any Edit/Delete buttons — only the `#itinerary-print-area` element is captured.
- If a day has no activities it still appears as a labelled day in the PDF with no activity rows.
- The PDF is a single page (best-effort for v1; very long itineraries may extend beyond a standard page size).

### Error & Loading States

- While the trip list is loading a centred spinner is shown; the list is not rendered yet.
- While a trip detail is loading a centred spinner is shown; the day panels are not rendered yet.
- A non-401 API error on any page shows an `ErrorBanner` at the top with the error message.
- A 401 response from the API at any point clears the auth session and redirects to `/login?expired=1`; the Login page shows "Your session has expired, please log in again" above the form.
- While any mutation is in-flight the triggering button shows a spinner and is disabled.
- If an activity edit or delete mutation fails (non-401), an inline error appears below the affected `ActivityItem`; the edit field remains open on edit failure.

### Responsive

- On a viewport narrower than 768 px the trip list renders as a single column.
- On a viewport 768 px or wider the trip list renders as a two-column grid.
- The itinerary page is fully usable on a 390 px wide viewport (iPhone portrait) without horizontal scrolling.
