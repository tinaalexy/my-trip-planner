from sqlmodel import Session, select
from fastapi import HTTPException
from app.models.user import User
from app.core.security import hash_password, verify_password, create_token
from app.schemas.auth import SignupRequest, LoginRequest, AuthResponse, UserOut


def signup(req: SignupRequest, db: Session) -> AuthResponse:
    existing = db.exec(select(User).where(User.username == req.username)).first()
    if existing:
        raise HTTPException(
            status_code=409,
            detail={"code": "USERNAME_TAKEN", "message": "Username already taken", "statusCode": 409},
        )
    user = User(username=req.username, password_hash=hash_password(req.password))
    db.add(user)
    db.commit()
    db.refresh(user)
    token = create_token(user.id, user.username)
    return AuthResponse(token=token, user=UserOut(id=user.id, username=user.username))


def login(req: LoginRequest, db: Session) -> AuthResponse:
    user = db.exec(select(User).where(User.username == req.username)).first()
    if not user or not verify_password(req.password, user.password_hash):
        raise HTTPException(
            status_code=401,
            detail={"code": "INVALID_CREDENTIALS", "message": "Invalid username or password", "statusCode": 401},
        )
    token = create_token(user.id, user.username)
    return AuthResponse(token=token, user=UserOut(id=user.id, username=user.username))
