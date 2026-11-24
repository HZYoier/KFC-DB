#!/usr/bin/env bash
# 一键演示：检测实例/数据库，必要时建 v1.0，启动应用并打开浏览器。
set -euo pipefail
cd "$(dirname "$0")"

PYTHON=".venv/Scripts/python.exe"
if [[ ! -x "$PYTHON" ]]; then
    PYTHON="python"
fi

exec "$PYTHON" demo_launcher.py "$@"
