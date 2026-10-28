"""应用工厂与蓝图注册（A 维护，计划 §7.1）。

run.py 启动入口归 C；这里只负责把配置、日志、错误处理和蓝图拼起来。
域模块只要在自己的包里给出 `bp`，就会被自动注册——C 的 app/auth、B 的 app/orders
建好目录即可接入，不用改这个文件。
"""

from __future__ import annotations

import importlib
import importlib.util

from flask import Flask

from app.common import errors, log
from app.common.config import DbConfig, load_db_config, load_env_file

# 蓝图模块按域固定；顺序只影响 URL 注册顺序，不影响路由匹配
BLUEPRINT_MODULES = ("app.auth", "app.master", "app.orders", "app.inventory")


def create_app(config: DbConfig | None = None) -> Flask:
    app = Flask(__name__)
    app.json.ensure_ascii = False  # 中文原样回显，页面层不再手工反转义

    app.config["KFC_DB"] = config or load_db_config()
    log.configure(app)
    errors.register_error_handlers(app)
    _register_blueprints(app)
    return app


def _register_blueprints(app: Flask) -> None:
    for name in BLUEPRINT_MODULES:
        if importlib.util.find_spec(name) is None:
            continue
        module = importlib.import_module(name)
        blueprint = getattr(module, "bp", None)
        if blueprint is not None:
            app.register_blueprint(blueprint)


__all__ = ["create_app", "load_env_file"]
