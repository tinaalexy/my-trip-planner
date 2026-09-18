from pydantic import Field, model_validator
from datetime import date, datetime
from typing import List
from app.schemas.base import CamelModel

VALID_TRIP_TYPES = ("solo", "couple", "family", "group_of_friends")


class TripCreate(CamelModel):
    destination: str = Field(min_length=1, max_length=100)
    start_date: date
    end_date: date
    trip_type: str

    @model_validator(mode="after")
    def validate_dates_and_type(self):
        if self.end_date < self.start_date:
            raise ValueError("end_date must be >= start_date")
        if self.trip_type not in VALID_TRIP_TYPES:
            raise ValueError(f"trip_type must be one of {VALID_TRIP_TYPES}")
        return self


class ActivityOut(CamelModel):
    id: str
    trip_id: str
    day_index: int
    text: str
    created_at: datetime
    updated_at: datetime


class TripOut(CamelModel):
    id: str
    destination: str
    start_date: date
    end_date: date
    trip_type: str
    created_at: datetime


class TripDetailOut(TripOut):
    activities: List[ActivityOut] = []
