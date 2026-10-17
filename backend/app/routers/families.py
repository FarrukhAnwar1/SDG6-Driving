# Driving Family endpoints. See flutter_driving_app/docs/driving_family.md.
import logging
from fastapi import APIRouter, HTTPException, status
from sqlalchemy import delete, select
from .. import models, schemas
from ..dependencies import CurrentUser, DbSession
from ..email import send_family_invitation_email
from ..security import generate_invitation_code, hash_invitation_code
from ..services.families import read_family
from ..services.family_transactions import (
    delete_family,
    lock_family,
    lock_membership,
    lock_user,
    mutate_family,
    revoke_invitations,
)

logger = logging.getLogger(__name__)
router = APIRouter(tags=["families"])


def family_error(status_code: int, code: str, message: str) -> HTTPException:
    return HTTPException(status_code, detail={"code": code, "message": message})


def require_family(db: DbSession, user: models.User) -> models.DrivingFamily:
    family = lock_membership(db, user)
    if family is None:
        raise family_error(
            status.HTTP_403_FORBIDDEN, "not_in_family", "You are not in a family."
        )
    return family


def require_admin(user: models.User, family: models.DrivingFamily) -> None:
    if family.admin_user_id != user.id:
        raise family_error(
            status.HTTP_403_FORBIDDEN,
            "admin_required",
            "Only the family admin can do that.",
        )


def require_no_family(user: models.User) -> None:
    if user.family_id is not None:
        raise family_error(
            status.HTTP_409_CONFLICT,
            "already_in_family",
            "You are already in a family. Leave it before joining another.",
        )


def invalid_invitation() -> HTTPException:
    return family_error(
        status.HTTP_400_BAD_REQUEST,
        "invalid_invitation",
        "This join code is invalid or has already been used. Check the code "
        "or ask the family admin for a new invitation.",
    )


@router.post(
    "/families", response_model=schemas.FamilyMeOut, status_code=status.HTTP_201_CREATED
)
def create_family(current_user: CurrentUser, db: DbSession):
    def create():
        # A new family never locks another family. Competing create/join
        # requests serialize on the user row.
        lock_user(db, current_user)
        require_no_family(current_user)
        family = models.DrivingFamily(admin_user_id=current_user.id)
        db.add(family)
        db.flush()
        current_user.family_id = family.id

    mutate_family(db, create)
    return get_my_family(current_user, db)


@router.get("/families/me", response_model=schemas.FamilyMeOut)
def get_my_family(current_user: CurrentUser, db: DbSession):
    if current_user.family_id is None:
        return schemas.FamilyMeOut(family=None)
    family = db.get(models.DrivingFamily, current_user.family_id)
    if family is None:
        return schemas.FamilyMeOut(family=None)
    return schemas.FamilyMeOut(family=read_family(db, family))


@router.post("/families/join", response_model=schemas.FamilyMeOut)
def join_family(
    payload: schemas.FamilyJoinRequest, current_user: CurrentUser, db: DbSession
):
    code_hash = hash_invitation_code(payload.code)

    def join():
        # Discover the family without locking the invitation out of order. This
        # snapshot is only a hint: revalidate the code with a current read below.
        family_id = db.scalar(
            select(models.FamilyInvitation.family_id).where(
                models.FamilyInvitation.code_hash == code_hash
            )
        )
        family = lock_family(db, family_id) if family_id is not None else None
        lock_user(db, current_user)
        require_no_family(current_user)
        if family is None:
            raise invalid_invitation()
        invitation = db.scalar(
            select(models.FamilyInvitation)
            .where(
                models.FamilyInvitation.code_hash == code_hash,
                models.FamilyInvitation.family_id == family.id,
            )
            .with_for_update()
            .execution_options(populate_existing=True)
        )
        if invitation is None:
            raise invalid_invitation()
        if invitation.email != schemas.normalize_email(current_user.email):
            raise family_error(
                status.HTTP_403_FORBIDDEN,
                "invitation_email_mismatch",
                "This invitation was sent to a different email address. Sign in with "
                "the invited account to join.",
            )
        current_user.family_id = family.id
        # Consume all codes for this family/recipient atomically. An older
        # invitation must not let the member bypass a later removal.
        revoke_invitations(db, family.id, current_user.email)

    mutate_family(db, join)
    return get_my_family(current_user, db)


@router.post("/families/leave", status_code=status.HTTP_204_NO_CONTENT)
def leave_family(current_user: CurrentUser, db: DbSession):
    def leave():
        family = require_family(db, current_user)
        if family.admin_user_id == current_user.id:
            # FOR UPDATE sees members committed since authentication. Every join
            # takes the family lock too, so none can slip past this check.
            other = db.scalar(
                select(models.User.id)
                .where(
                    models.User.family_id == family.id,
                    models.User.id != current_user.id,
                )
                .limit(1)
                .with_for_update()
            )
            if other is not None:
                raise family_error(
                    status.HTTP_409_CONFLICT,
                    "admin_cannot_leave",
                    "The admin can't leave while other members remain. Remove them first.",
                )
            current_user.family_id = None
            delete_family(db, family)
        else:
            current_user.family_id = None
            revoke_invitations(db, family.id, current_user.email)

    mutate_family(db, leave)


@router.post("/families/me/invitations", status_code=status.HTTP_204_NO_CONTENT)
def invite_to_family(
    payload: schemas.FamilyInvitationCreate, current_user: CurrentUser, db: DbSession
):
    def invite():
        family = require_family(db, current_user)
        require_admin(current_user, family)
        code = generate_invitation_code()
        invitation = models.FamilyInvitation(
            family_id=family.id,
            email=payload.email,
            invited_by_user_id=current_user.id,
            code_hash=hash_invitation_code(code),
        )
        db.add(invitation)
        db.flush()
        return invitation.id, code, current_user.username

    invitation_id, code, inviter = mutate_family(db, invite)
    try:
        # Outside the retried transaction: a deadlock must not send duplicate mail.
        send_family_invitation_email(payload.email, code, inviter)
    except Exception:
        logger.exception("Failed to send family invitation email.")

        def discard():
            db.execute(
                delete(models.FamilyInvitation).where(
                    models.FamilyInvitation.id == invitation_id
                )
            )

        mutate_family(db, discard)
        raise HTTPException(
            status.HTTP_502_BAD_GATEWAY, "Could not send the invitation email."
        )


@router.delete(
    "/families/me/members/{user_id}", status_code=status.HTTP_204_NO_CONTENT
)
def remove_family_member(user_id: int, current_user: CurrentUser, db: DbSession):
    def remove():
        family = require_family(db, current_user)
        require_admin(current_user, family)
        if user_id == current_user.id:
            raise HTTPException(
                status.HTTP_400_BAD_REQUEST,
                "To leave your own family, use POST /families/leave.",
            )
        member = db.scalar(
            select(models.User)
            .where(models.User.id == user_id, models.User.family_id == family.id)
            .with_for_update()
            .execution_options(populate_existing=True)
        )
        if member is None:
            raise HTTPException(
                status.HTTP_404_NOT_FOUND, "That user is not a member of your family."
            )
        member.family_id = None
        revoke_invitations(db, family.id, member.email)

    mutate_family(db, remove)
