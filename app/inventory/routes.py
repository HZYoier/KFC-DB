"""库存域页面层：库存看板、流水、补货建议与收货。"""

from __future__ import annotations

from flask import Blueprint, redirect, render_template, request, url_for

from app.auth import current_employee_session, current_identity, login_required
from app.auth import service as auth_service
from app.common.errors import AppError
from app.inventory import service

bp = Blueprint("inventory", __name__, url_prefix="/inventory")


def _employee_id(identity) -> int:
    return int(identity["employee"]["employee_id"])


def _render(identity, session, *, error=None, notice=None, ingredient_id=None):
    try:
        inventory = service.list_inventory(session)
        movements = service.list_movements(session, ingredient_id)
        suggestions = service.list_replenishment(session)
        load_error = None
    except AppError as err:
        if auth_service.clear_if_stale(err):
            return redirect(url_for("auth.login", next=request.path))
        inventory, movements, suggestions = [], [], []
        load_error = err.user_message

    return render_template(
        "inventory/index.html",
        identity=identity,
        inventory=inventory,
        movements=movements,
        suggestions=suggestions,
        allowed=service.allowed_actions(identity),
        error=error or load_error,
        notice=notice,
        ingredient_id=ingredient_id or "",
    )


def _after_action(identity, session, action, *, ingredient_id=None):
    try:
        action()
    except AppError as err:
        if auth_service.clear_if_stale(err):
            return redirect(url_for("auth.login", next=request.path))
        return _render(identity, session, error=err.user_message, ingredient_id=ingredient_id), err.http_status
    return redirect(url_for("inventory.index", ok=1))


@bp.get("/")
@login_required
def index():
    identity = current_identity()
    session = current_employee_session()
    ingredient = request.args.get("ingredient_id") or None
    notice = "已提交" if request.args.get("ok") else None
    return _render(identity, session, notice=notice, ingredient_id=ingredient)


@bp.post("/adjust")
@login_required
def adjust():
    identity = current_identity()
    session = current_employee_session()
    return _after_action(
        identity,
        session,
        lambda: service.adjust_inventory(
            session,
            _employee_id(identity),
            request.form.get("ingredient_id"),
            request.form.get("on_hand_delta"),
            request.form.get("reason"),
        ),
    )


@bp.post("/replenishment/create")
@login_required
def create_suggestion():
    identity = current_identity()
    session = current_employee_session()
    return _after_action(
        identity,
        session,
        lambda: service.create_suggestion(
            session,
            _employee_id(identity),
            request.form.get("ingredient_id"),
            request.form.get("suggested_qty"),
        ),
    )


@bp.post("/replenishment/<int:suggestion_id>/update")
@login_required
def update_suggestion(suggestion_id: int):
    identity = current_identity()
    session = current_employee_session()
    return _after_action(
        identity,
        session,
        lambda: service.update_suggestion(
            session, _employee_id(identity), suggestion_id, request.form.get("suggested_qty")
        ),
    )


@bp.post("/replenishment/<int:suggestion_id>/submit")
@login_required
def submit_suggestion(suggestion_id: int):
    identity = current_identity()
    session = current_employee_session()
    return _after_action(
        identity,
        session,
        lambda: service.submit_suggestion(session, _employee_id(identity), suggestion_id),
    )


@bp.post("/replenishment/<int:suggestion_id>/approve")
@login_required
def approve_suggestion(suggestion_id: int):
    identity = current_identity()
    session = current_employee_session()
    return _after_action(
        identity,
        session,
        lambda: service.approve_suggestion(session, _employee_id(identity), suggestion_id),
    )


@bp.post("/replenishment/<int:suggestion_id>/reject")
@login_required
def reject_suggestion(suggestion_id: int):
    identity = current_identity()
    session = current_employee_session()
    return _after_action(
        identity,
        session,
        lambda: service.reject_suggestion(
            session,
            _employee_id(identity),
            suggestion_id,
            request.form.get("reason"),
        ),
    )


@bp.get("/roles")
@login_required
def roles():
    identity = current_identity()
    session = current_employee_session()
    try:
        rows = service.list_employee_roles(session)
        error = None
    except AppError as err:
        if auth_service.clear_if_stale(err):
            return redirect(url_for("auth.login", next=request.path))
        rows, error = [], err.user_message
    return render_template("inventory/roles.html", identity=identity, rows=rows, error=error)


@bp.post("/receive")
@login_required
def receive():
    identity = current_identity()
    session = current_employee_session()
    return _after_action(
        identity,
        session,
        lambda: service.receive_inventory(
            session,
            _employee_id(identity),
            request.form.get("purchase_order_id"),
            request.form.get("received_qty"),
        ),
    )
