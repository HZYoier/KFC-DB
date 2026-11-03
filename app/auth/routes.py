"""登录/注销/身份首页（C 域）。"""

from __future__ import annotations

from flask import Blueprint, redirect, render_template, request, url_for

from app.auth import service
from app.common.errors import AppError

bp = Blueprint("auth", __name__)

_LOGIN_FAILED = "账号或口令不正确，或账号已停用。"
_DB_UNAVAILABLE = "数据库暂时不可用，请稍后重试。"
_INPUT_REQUIRED = "请输入数据库登录名和口令。"


def _safe_next(target: str | None) -> str:
    if target and target.startswith("/") and not target.startswith("//"):
        return target
    return url_for("auth.index")


def _error_message(err: AppError) -> str:
    if err.code == "E_INPUT":
        return _INPUT_REQUIRED
    if err.code == "E_DB":
        return _DB_UNAVAILABLE
    if err.code == "E_AUTH":
        return _LOGIN_FAILED
    return err.user_message


@bp.get("/login")
def login():
    if service.current_employee_session() is not None:
        return redirect(url_for("auth.index"))
    return render_template("auth/login.html", error=None, next=request.args.get("next", ""), login="")


@bp.post("/login")
def login_submit():
    login_name = request.form.get("login", "")
    password = request.form.get("password", "")
    next_target = request.form.get("next", "")
    try:
        service.authenticate(login_name, password)
    except AppError as err:
        return (
            render_template(
                "auth/login.html",
                error=_error_message(err),
                next=next_target,
                login=login_name.strip(),
            ),
            err.http_status,
        )
    return redirect(_safe_next(next_target))


@bp.post("/logout")
def logout():
    service.logout()
    return redirect(url_for("auth.login"))


@bp.get("/")
@service.login_required
def index():
    identity = service.current_identity()
    if identity is None:
        return redirect(url_for("auth.login"))
    return render_template("auth/index.html", identity=identity)
