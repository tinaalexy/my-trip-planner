from sqlmodel import create_engine, Session
from app.core.config import settings

engine = create_engine(
    settings.database_url,
    connect_args={"check_same_thread": False},
)


def get_session():
    with Session(engine) as session:
        yield session
