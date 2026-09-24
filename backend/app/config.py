# Contains the configuration/env settings
from urllib.parse import quote_plus
from pydantic import Field
from pydantic_settings import BaseSettings, SettingsConfigDict

class Settings(BaseSettings):
    model_config = SettingsConfigDict(env_file=".env", extra="ignore")

    app_name: str = "SDG6 Driving API"

    # MySQL connection (fill these in .env)
    db_host: str = "localhost"   # Host / IP
    db_port: int = 3306          # Port
    db_name: str = "driving"     # Database name
    db_user: str = "root"        # Username
    db_password: str = ""        # Password

    # for frontend
    cors_origins: list[str] = ["http://localhost:3000"]

    # email verification
    jwt_secret_key: str = "secret-change-me"    # Signing key
    jwt_algorithm: str = "HS256"                # HMAC algorithm
    verification_token_expire_hours: int = 24   # Link expiration
    access_token_expire_minutes: int = 60 * 24

    # forgot password (email a 6-digit code, verified in-app - no email deep links needed)
    password_reset_code_expire_minutes: int = 15  # Code validity window
    password_reset_max_attempts: int = 5          # Wrong tries allowed before a new code is required

    # Resending emails
    resend_api_key: str = ""                    # Resend API key
    from_email: str = ""
    api_base_url: str = ""

    # Optional until GET /advanced-suggestion has enough history to use Gemini
    gemini_api_key: str = ""
    gemini_model: str = "gemini-3.5-flash-lite"
    gemini_timeout_seconds: float = Field(default=30, gt=0, le=120)

    # Assume a limit on roads with no maxspeed tag, from the road's class.
    # Off by default: the app grades every limit at a flat 5 mph tolerance, and
    # an assumed limit needs more slack than that (GET /speed-limit sends the
    # right tolerance as speedingThresholdMph, but nothing reads it yet).
    # Turn on once the app honors that field
    speed_limit_inference_enabled: bool = False

    # PostGIS connection for speed-limit data (separate DB from the MySQL above)
    pg_host: str = "localhost"
    pg_port: int = 5432
    pg_name: str = "speedlimits"
    pg_user: str = "sdg6"
    pg_password: str = ""

    @property
    def database_url(self) -> str:
        # quote_plus escapes special characters (@, :, /, etc.) in the password
        pwd = quote_plus(self.db_password)
        return (
            f"mysql+pymysql://{self.db_user}:{pwd}"
            f"@{self.db_host}:{self.db_port}/{self.db_name}"
        )

    @property
    def postgis_url(self) -> str:
        pwd = quote_plus(self.pg_password)
        return (
            f"postgresql+psycopg://{self.pg_user}:{pwd}"
            f"@{self.pg_host}:{self.pg_port}/{self.pg_name}"
        )

settings = Settings()
