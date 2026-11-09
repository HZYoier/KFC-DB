"""A 域 JSON 接口层：把页面已经在用的 service 原样暴露成 JSON，不新开数据库路径。

- `GET  /api/csrf`                      出 CSRF 令牌（页面另有 `<meta>`，两边同值）
- `GET  /api/master/meta`               九实体与十八动作的字段清单，前端不硬编码
- `GET  /api/master/<entity>`           列表，复用 `sp_list_master_records`（契约 §2.4.1）
- `POST /api/master/<entity>/<action>`  写入，复用 `app/master/routes.py` 的 ACTIONS 表

身份仍由 `app/master/routes.py` 的 `current_session()` 取（C 的登录层写会话即可接入），
判定仍在数据库。错误不走页面模板：直接抛 `AppError`，由 `app/common/errors` 的全局
处理器输出 `{code, message, request_id}`，与页面层是同一张九类表。
"""

from __future__ import annotations

from flask import Blueprint

bp = Blueprint("api", __name__, url_prefix="/api")

from app.api import master as _master  # noqa: E402,F401  只为注册路由

__all__ = ["bp"]
