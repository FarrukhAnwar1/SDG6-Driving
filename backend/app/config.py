from urllib.parse import quote_plus
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
    from_email: str = "onboarding@resend.dev"   # sandbox email for now
    api_base_url: str = "http://localhost:8000"  

    @property
    def database_url(self) -> str:
        # quote_plus escapes special characters (@, :, /, etc.) in the password
        pwd = quote_plus(self.db_password)
        return (
            f"mysql+pymysql://{self.db_user}:{pwd}"
            f"@{self.db_host}:{self.db_port}/{self.db_name}"
        )

settings = Settings()
