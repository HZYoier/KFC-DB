"""员工登录与请求身份（C 域）。

蓝图由 `app/__init__.py` 的 `BLUEPRINT_MODULES` 自动注册；A 的 `app/master` 通过
`current_employee_session()` 取得本请求的员工数据库凭据。密码只保存在本进程的
服务端内存里，Flask 会话只放随机 token——不把口令写进签名 cookie。
"""

from app.auth.routes import bp
# 导入即把顾客自助路由挂到同一个 auth.bp 上；不要求员工登录，也不新增蓝图模块。
from app.auth import customer as _customer  # noqa: F401
from app.auth.service import current_employee_session, current_identity, login_required

__all__ = ["bp", "current_employee_session", "current_identity", "login_required"]
