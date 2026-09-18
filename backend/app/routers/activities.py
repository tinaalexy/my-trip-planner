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
def add_activity(
    trip_id: str,
    req: ActivityCreate,
    user: User = Depends(get_current_user),
    db: Session = Depends(get_session),
):
    return activity_service.add_activity(trip_id, req, user, db)


@router.put("/{activity_id}", response_model=ActivityOut)
def update_activity(
    trip_id: str,
    activity_id: str,
    req: ActivityUpdate,
    user: User = Depends(get_current_user),
    db: Session = Depends(get_session),
):
    return activity_service.update_activity(trip_id, activity_id, req, user, db)


@router.delete("/{activity_id}", status_code=204)
def delete_activity(
    trip_id: str,
    activity_id: str,
    user: User = Depends(get_current_user),
    db: Session = Depends(get_session),
):
    activity_service.delete_activity(trip_id, activity_id, user, db)
