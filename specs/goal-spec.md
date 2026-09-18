# Goal Spec – Trip Planner

> Defines *what* we're building and *why*. Fill this in first – the other specs should derive from it.

## 1. Problem Statement

Travelers planning a trip to a destination typically scatter their day-by-day plans across notes apps, spreadsheets, or chat threads, making it hard to keep an itinerary organized, share it, or reference it while traveling. This app gives travelers a single place to plan their trip day by day and export a clean itinerary.

## 2. Target Users

Any traveler planning a trip, regardless of who they're traveling with – solo, as a couple, with family, or with a group of friends.

## 3. Core Use Cases

- As a user, I want to create a trip and add destinations so that I can see my itinerary in one place.
- For each destination, I want to enter the start and end date of the trip, and plan my activities in a day-by-day manner.
- After the plan is finalized, I want to print out the itinerary as a PDF.

## 4. Core Features (MVP)

- Responsive web application (usable on both desktop and mobile browsers – no native mobile app)
- Users can sign up (username + password) and log in through login/signup screens
- Users can create a new trip with a destination, start date, end date, and trip type (solo, couple, family, group of friends)
- Users can open a trip's plan and enter activities day by day, from Day 1 through Day N (derived from the trip's start/end dates)
- Users can view a list of their created trips
- Users can export a finalized trip's itinerary as a PDF

## 5. Nice-to-Have Features (Post-MVP)

- User authentication workflow with email

## 6. Out of Scope

- Auto-populate day-by-day plan through a drop-down
- Auto-populate suggestions on the basis of trip type
- Editing a trip's destination, dates, or type after creation

## 7. Success Metrics

- A user is able to log in
- A user is able to create a trip
- A user is able to see their created trips
- A user is able to plan day-by-day activities for a trip
- A user is able to export a trip's itinerary as a PDF

## 8. Constraints & Assumptions

- Timeline: 2 weekends
- Team Size: 1 person
- Target Platform: Web only, built responsively so it also works on mobile browsers (no native mobile app)

## 9. Glossary

| Term | Definition |
|------|------------|
| Trip | A single planned journey to one destination, with a start date, end date, trip type, and a day-by-day itinerary. Owned by the user who created it. |
| Destination | The place a Trip is planned for (e.g. a city or region). One Trip has exactly one destination. |
| Trip Type | Classifies who a Trip is for: Solo, Couple, Family, or Group of Friends. |
| Itinerary | The full day-by-day plan for a Trip, made up of one Day entry for each date from the Trip's start date to its end date. |
| Day | A single date within a Trip's date range, identified by its day number (Day 1 – Day N), holding the Activities planned for that date. |
| Activity | A free-text entry describing something planned for a given Day within a Trip. |
| User | A person who has logged in and can create, view, and manage their own Trips. |
| Itinerary Export | A generated PDF document of a Trip's finalized Itinerary, suitable for printing or offline reference. |
