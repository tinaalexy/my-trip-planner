import jwt
from fastapi import Depends, HTTPException
from fastapi.security import HTTPBearer, HTTPAuthorizationCredentials
from sqlmodel import Session, select
from app.database import get_session
from app.models.user import User
from app.core.security import decode_token

bearer = HTTPBearer()


def get_current_user(
    credentials: HTTPAuthorizationCredentials = Depends(bearer),
    db: Session = Depends(get_session),
) -> User:
    try:
        payload = decode_token(credentials.credentials)
    except jwt.ExpiredSignatureError:
        raise HTTPException(
            status_code=401,
            detail={"code": "UNAUTHORIZED", "message": "Token expired", "statusCode": 401},
        )
    except jwt.InvalidTokenError:
        raise HTTPException(
            status_code=401,
            detail={"code": "UNAUTHORIZED", "message": "Invalid token", "statusCode": 401},
        )
    user = db.exec(select(User).where(User.id == payload["sub"])).first()
    if not user:
        raise HTTPException(
            status_code=401,
            detail={"code": "UNAUTHORIZED", "message": "User not found", "statusCode": 401},
        )
    return user
