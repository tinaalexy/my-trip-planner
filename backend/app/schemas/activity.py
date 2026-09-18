from pydantic import Field
from app.schemas.base import CamelModel


class ActivityCreate(CamelModel):
    day_index: int = Field(ge=1)
    text: str = Field(min_length=1, max_length=300)


class ActivityUpdate(CamelModel):
    text: str = Field(min_length=1, max_length=300)
