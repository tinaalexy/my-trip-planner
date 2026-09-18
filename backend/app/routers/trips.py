from fastapi import APIRouter, Depends
from sqlmodel import Session
from typing import List
from app.database import get_session
from app.dependencies.auth import get_current_user
from app.models.user import User
from app.schemas.trip import TripCreate, TripOut, TripDetailOut
from app.services import trip_service

router = APIRouter(prefix="/api/v1/trips", tags=["trips"])


@router.get("", response_model=List[TripOut])
def list_trips(user: User = Depends(get_current_user), db: Session = Depends(get_session)):
    return trip_service.list_trips(user, db)


@router.post("", response_model=TripOut, status_code=201)
def create_trip(
    req: TripCreate,
    user: User = Depends(get_current_user),
    db: Session = Depends(get_session),
):
    return trip_service.create_trip(req, user, db)


@router.get("/{trip_id}", response_model=TripDetailOut)
def get_trip(
    trip_id: str,
    user: User = Depends(get_current_user),
    db: Session = Depends(get_session),
):
    return trip_service.get_trip(trip_id, user, db)


@router.delete("/{trip_id}", status_code=204)
def delete_trip(
    trip_id: str,
    user: User = Depends(get_current_user),
    db: Session = Depends(get_session),
):
    trip_service.delete_trip(trip_id, user, db)
