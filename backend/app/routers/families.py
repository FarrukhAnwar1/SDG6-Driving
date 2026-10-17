# Driving Family endpoints. The contract is in
# flutter_driving_app/docs/driving_family.md. Every membership-changing handler
# locks the caller's user row first so concurrent create/join/leave calls can't
# overwrite each other.
import logging
from fastapi import APIRouter, HTTPException, status
from sqlalchemy import func, select
from .. import models, schemas
from ..dependencies import CurrentUser, DbSession
from ..email import send_family_invitation_email
from ..security import generate_invitation_code, hash_invitation_code
from ..services.families import read_family

logger = logging.getLogger(__name__)
router = APIRouter(tags=["families"])


def family_error(status_code: int, code: str, message: str) -> HTTPException:
    # Shape the app expects: detail.code (machine readable) and detail.message
    return HTTPException(status_code, detail={"code": code, "message": message})


def lock_user(db: DbSession, user: models.User) -> None:
    db.refresh(user, with_for_update=True)


def require_family(db: DbSession, user: models.User) -> models.DrivingFamily:
    """The caller's family, locked, or 403 not_in_family."""
    family = None
    if user.family_id is not None:
        family = db.scalar(
            select(models.DrivingFamily)
            .where(models.DrivingFamily.id == user.family_id)
            .with_for_update()
        )
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


@router.post(
    "/families", response_model=schemas.FamilyMeOut, status_code=status.HTTP_201_CREATED
)
def create_family(current_user: CurrentUser, db: DbSession):
    lock_user(db, current_user)
    if current_user.family_id is not None or current_user.administered_family:
        raise family_error(
            status.HTTP_409_CONFLICT, "already_in_family", "You are already in a family."
        )

    family = models.DrivingFamily(admin_user_id=current_user.id)
    db.add(family)
    db.flush()  # assigns family.id
    current_user.family_id = family.id  # the admin is also a member
    db.commit()
    db.refresh(family)
    return schemas.FamilyMeOut(family=read_family(db, family))


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
    lock_user(db, current_user)
    if current_user.family_id is not None:
        raise family_error(
            status.HTTP_409_CONFLICT,
            "already_in_family",
            "You are already in a family. Leave it before joining another.",
        )

    # Lock the invitation so two requests can't redeem the same code
    invitation = db.scalar(
        select(models.FamilyInvitation)
        .where(models.FamilyInvitation.code_hash == hash_invitation_code(payload.code))
        .with_for_update()
    )
    if invitation is None:
        raise family_error(
            status.HTTP_400_BAD_REQUEST,
            "invalid_invitation",
            "This join code is invalid or has already been used. Check the code "
            "or ask the family admin for a new invitation.",
        )

    # Compare against the account's email, never anything the client sent. A
    # mismatch leaves the invitation intact for its intended recipient, and
    # doesn't reveal which email it was for
    if invitation.email != schemas.normalize_email(current_user.email):
        raise family_error(
            status.HTTP_403_FORBIDDEN,
            "invitation_email_mismatch",
            "This invitation was sent to a different email address. Sign in with "
            "the invited account to join.",
        )

    # One transaction: add the member and delete the invitation, or neither
    current_user.family_id = invitation.family_id
    db.delete(invitation)
    db.commit()

    family = db.get(models.DrivingFamily, current_user.family_id)
    return schemas.FamilyMeOut(family=read_family(db, family))


@router.post("/families/leave", status_code=status.HTTP_204_NO_CONTENT)
def leave_family(current_user: CurrentUser, db: DbSession):
    lock_user(db, current_user)
    family = require_family(db, current_user)

    if family.admin_user_id == current_user.id:
        others = db.scalar(
            select(func.count())
            .select_from(models.User)
            .where(
                models.User.family_id == family.id,
                models.User.id != current_user.id,
            )
        )
        if others:
            raise family_error(
                status.HTTP_409_CONFLICT,
                "admin_cannot_leave",
                "The admin can't leave while other members remain. "
                "Remove them first.",
            )
        # Last one out: clear own family_id first (the users <-> driving_families
        # FKs point at each other), then delete the family. Its invitations go
        # with it through the ORM cascade
        current_user.family_id = None
        db.flush()
        db.delete(family)
    else:
        current_user.family_id = None

    db.commit()


@router.post(
    "/families/me/invitations", status_code=status.HTTP_204_NO_CONTENT
)
def invite_to_family(
    payload: schemas.FamilyInvitationCreate, current_user: CurrentUser, db: DbSession
):
    family = require_family(db, current_user)
    require_admin(current_user, family)

    code = generate_invitation_code()
    invitation = models.FamilyInvitation(
        family_id=family.id,
        email=payload.email,  # already normalized by the schema
        invited_by_user_id=current_user.id,  # from the token, never the body
        code_hash=hash_invitation_code(code),
    )
    db.add(invitation)
    db.commit()

    try:
        send_family_invitation_email(payload.email, code, current_user.username)
    except Exception:
        logger.exception("Failed to send family invitation email.")
        # Don't leave a code nobody received sitting in the table
        db.delete(invitation)
        db.commit()
        raise HTTPException(
            status.HTTP_502_BAD_GATEWAY, "Could not send the invitation email."
        )


@router.delete(
    "/families/me/members/{user_id}", status_code=status.HTTP_204_NO_CONTENT
)
def remove_family_member(user_id: int, current_user: CurrentUser, db: DbSession):
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
    )
    if member is None:
        raise HTTPException(
            status.HTTP_404_NOT_FOUND, "That user is not a member of your family."
        )

    # Their accounts and reports are untouched, and a redeemed invitation is
    # not recreated, so rejoining needs a new invitation
    member.family_id = None
    db.commit()