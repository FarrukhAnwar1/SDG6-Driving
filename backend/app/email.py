import resend
import html
from .config import settings

resend.api_key = settings.resend_api_key

def send_verification_email(to_email: str, token: str) -> None:
    verify_link = f"{settings.api_base_url}/verify-email?token={token}"
    resend.Emails.send({
        "from": settings.from_email,
        "to": to_email,
        "subject": "Verify your email",
        "html": (
            f"<p>Click the link below to verify your email address. "
            f"This link will expire in {settings.verification_token_expire_hours} hours.</p>"
            f'<p><a href="{verify_link}">Verify Email</a></p>'
        ),
    })

# Sends a short-lived numeric code rather than a link, entered directly in the
# app, this avoids relying on email-app-to-mobile-app deep linking
def send_password_reset_email(to_email: str, code: str) -> None:
    resend.Emails.send({
        "from": settings.from_email,
        "to": to_email,
        "subject": "Your password reset code",
        "html": (
            "<p>Use the code below to reset your password:</p>"
            f'<p style="font-size:28px;font-weight:bold;letter-spacing:6px;">{code}</p>'
            f"<p>This code will expire in {settings.password_reset_code_expire_minutes} minutes.</p>"
            "<p>If you didn't request a password reset, you can safely ignore this email.</p>"
        ),
    })

def send_family_invitation_email(to_email: str, code: str, inviter_username: str) -> None:
    inviter = html.escape(inviter_username)
    resend.Emails.send({
        "from": settings.from_email,
        "to": to_email,
        "subject": f"{inviter} invited you to join their family on {settings.app_name}",
        "html": (
            f"<p>{inviter} has invited you to join their Driving Family.</p>"
            "<p>Sign in to the app with this email address, open Driving Family, "
            "choose Join Family, and enter this code:</p>"
            f'<p style="font-size:16px;font-weight:bold;">{code}</p>'
            "<p>This code can only be used once.</p>"
        ),
    })