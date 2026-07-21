from sqlalchemy import create_engine
from sqlalchemy.orm import DeclarativeBase, sessionmaker
from .config import settings

engine = create_engine(
    settings.database_url,
    pool_pre_ping=True,   # transparently recovers from dropped MySQL connections
)

SessionLocal = sessionmaker(autocommit=False, autoflush=False, bind=engine)

# Second connection: PostGIS (speed-limit data), fully independent of the MySQL engine
pg_engine = create_engine(settings.postgis_url, pool_pre_ping=True)
PgSessionLocal = sessionmaker(autocommit=False, autoflush=False, bind=pg_engine)

class Base(DeclarativeBase):
    pass
