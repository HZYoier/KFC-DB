"""KFC-DB 2.3 启动入口（C）。

用法（仓库根目录，先准备 .env 或环境变量）：
    python run.py
"""

from __future__ import annotations

import os

from app import create_app, load_env_file


def main() -> None:
    load_env_file()
    app = create_app()
    host = (os.environ.get("KFC_APP_HOST") or "127.0.0.1").strip()
    port = int((os.environ.get("KFC_APP_PORT") or "5000").strip())
    debug = (os.environ.get("KFC_APP_DEBUG") or "").strip().lower() in ("1", "true", "yes")
    app.run(host=host, port=port, debug=debug, use_reloader=debug)


if __name__ == "__main__":
    main()
