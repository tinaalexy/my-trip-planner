from datetime import datetime, timezone
from sqlmodel import Session, select
from fastapi import HTTPException
from app.models.trip import Trip
from app.models.activity import Activity
from app.models.user import User
from app.schemas.activity import ActivityCreate, ActivityUpdate
from app.schemas.trip import ActivityOut


def _get_owned_trip(trip_id: str, user: User, db: Session) -> Trip:
    trip = db.exec(
        select(Trip).where(Trip.id == trip_id, Trip.user_id == user.id)
    ).first()
    if not trip:
        raise HTTPException(
            status_code=404,
            detail={"code": "RESOURCE_NOT_FOUND", "message": "Trip not found", "statusCode": 404},
        )
    return trip


def add_activity(trip_id: str, req: ActivityCreate, user: User, db: Session) -> ActivityOut:
    trip = _get_owned_trip(trip_id, user, db)
    max_day = (trip.end_date - trip.start_date).days + 1
    if req.day_index > max_day:
        raise HTTPException(
            status_code=400,
            detail={
                "code": "INVALID_DAY_INDEX",
                "message": f"dayIndex must be between 1 and {max_day}",
                "statusCode": 400,
            },
        )
    activity = Activity(trip_id=trip_id, day_index=req.day_index, text=req.text)
    db.add(activity)
    db.commit()
    db.refresh(activity)
    return ActivityOut.model_validate(activity)


def update_activity(
    trip_id: str, activity_id: str, req: ActivityUpdate, user: User, db: Session
) -> ActivityOut:
    _get_owned_trip(trip_id, user, db)
    activity = db.exec(
        select(Activity).where(Activity.id == activity_id, Activity.trip_id == trip_id)
    ).first()
    if not activity:
        raise HTTPException(
            status_code=404,
            detail={"code": "RESOURCE_NOT_FOUND", "message": "Activity not found", "statusCode": 404},
        )
    activity.text = req.text
    activity.updated_at = datetime.now(timezone.utc)
    db.add(activity)
    db.commit()
    db.refresh(activity)
    return ActivityOut.model_validate(activity)


def delete_activity(trip_id: str, activity_id: str, user: User, db: Session):
    _get_owned_trip(trip_id, user, db)
    activity = db.exec(
        select(Activity).where(Activity.id == activity_id, Activity.trip_id == trip_id)
    ).first()
    if not activity:
        raise HTTPException(
            status_code=404,
            detail={"code": "RESOURCE_NOT_FOUND", "message": "Activity not found", "statusCode": 404},
        )
    db.delete(activity)
    db.commit()
