from sqlmodel import SQLModel, Field, Relationship
from uuid import uuid4
from datetime import datetime, timezone
from typing import Optional, TYPE_CHECKING

if TYPE_CHECKING:
    from app.models.trip import Trip


class Activity(SQLModel, table=True):
    id: str = Field(default_factory=lambda: str(uuid4()), primary_key=True)
    trip_id: str = Field(foreign_key="trip.id", index=True)
    day_index: int
    text: str
    created_at: datetime = Field(default_factory=lambda: datetime.now(timezone.utc))
    updated_at: datetime = Field(default_factory=lambda: datetime.now(timezone.utc))
    trip: Optional["Trip"] = Relationship(back_populates="activities")
