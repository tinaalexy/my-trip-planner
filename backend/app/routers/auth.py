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
