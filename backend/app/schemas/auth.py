from pydantic import Field
from app.schemas.base import CamelModel


class SignupRequest(CamelModel):
    username: str = Field(min_length=3, max_length=30, pattern=r"^[a-zA-Z0-9_]+$")
    password: str = Field(min_length=8)


class LoginRequest(CamelModel):
    username: str = Field(min_length=1)
    password: str = Field(min_length=1)


class UserOut(CamelModel):
    id: str
    username: str


class AuthResponse(CamelModel):
    token: str
    user: UserOut
