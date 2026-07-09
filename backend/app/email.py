import resend
from .config import settings

resend.api_key = settings.resend_api_key

def send_verification_email(to_email: str, token: str) -> None:
    verify_link = f"{settings.api_base_url}/auth/verify-email?token={token}"
    resend.Emails.send({
        "from": settings.from_email,
        "to": to_email,
        "subject": "Verify your email",
        "html": (
            f"<p>Click the link below to verify your email address:"
            f"This link will expire in {settings.verification_token_expire_hours} hours.</p>"
            f'<p><a href="{verify_link}">Verify Email</a></p>'
        ),
    })