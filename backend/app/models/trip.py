from sqlmodel import SQLModel, Field, Relationship
from uuid import uuid4
from datetime import datetime, date, timezone
from typing import List, TYPE_CHECKING

if TYPE_CHECKING:
    from app.models.activity import Activity


class Trip(SQLModel, table=True):
    id: str = Field(default_factory=lambda: str(uuid4()), primary_key=True)
    user_id: str = Field(foreign_key="user.id", index=True)
    destination: str
    start_date: date
    end_date: date
    trip_type: str
    created_at: datetime = Field(default_factory=lambda: datetime.now(timezone.utc))
    activities: List["Activity"] = Relationship(
        back_populates="trip",
        sa_relationship_kwargs={"cascade": "all, delete-orphan", "lazy": "select"},
    )
