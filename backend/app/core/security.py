import jwt
import bcrypt
from datetime import datetime, timedelta, timezone
from app.core.config import settings


def hash_password(plain: str) -> str:
    return bcrypt.hashpw(plain.encode(), bcrypt.gensalt(rounds=12)).decode()


def verify_password(plain: str, hashed: str) -> bool:
    return bcrypt.checkpw(plain.encode(), hashed.encode())


def create_token(user_id: str, username: str) -> str:
    expire = datetime.now(timezone.utc) + timedelta(days=settings.jwt_expires_days)
    return jwt.encode(
        {"sub": user_id, "username": username, "exp": expire},
        settings.jwt_secret,
        algorithm="HS256",
    )


def decode_token(token: str) -> dict:
    return jwt.decode(token, settings.jwt_secret, algorithms=["HS256"])
