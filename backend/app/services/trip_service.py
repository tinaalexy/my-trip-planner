from sqlmodel import Session, select
from fastapi import HTTPException
from app.models.trip import Trip
from app.models.activity import Activity
from app.models.user import User
from app.schemas.trip import TripCreate, TripOut, TripDetailOut, ActivityOut


def list_trips(user: User, db: Session):
    trips = db.exec(
        select(Trip).where(Trip.user_id == user.id).order_by(Trip.created_at.desc())
    ).all()
    return [TripOut.model_validate(t) for t in trips]


def create_trip(req: TripCreate, user: User, db: Session) -> TripOut:
    trip = Trip(
        user_id=user.id,
        destination=req.destination,
        start_date=req.start_date,
        end_date=req.end_date,
        trip_type=req.trip_type,
    )
    db.add(trip)
    db.commit()
    db.refresh(trip)
    return TripOut.model_validate(trip)


def get_trip(trip_id: str, user: User, db: Session) -> TripDetailOut:
    trip = db.exec(
        select(Trip).where(Trip.id == trip_id, Trip.user_id == user.id)
    ).first()
    if not trip:
        raise HTTPException(
            status_code=404,
            detail={"code": "RESOURCE_NOT_FOUND", "message": "Trip not found", "statusCode": 404},
        )
    activities = db.exec(
        select(Activity)
        .where(Activity.trip_id == trip_id)
        .order_by(Activity.day_index, Activity.created_at)
    ).all()
    out = TripDetailOut.model_validate(trip)
    out.activities = [ActivityOut.model_validate(a) for a in activities]
    return out


def delete_trip(trip_id: str, user: User, db: Session):
    trip = db.exec(
        select(Trip).where(Trip.id == trip_id, Trip.user_id == user.id)
    ).first()
    if not trip:
        raise HTTPException(
            status_code=404,
            detail={"code": "RESOURCE_NOT_FOUND", "message": "Trip not found", "statusCode": 404},
        )
    db.delete(trip)
    db.commit()
