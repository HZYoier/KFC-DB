"""实库探针：以真实员工登录、打真实 v1.0 库，验证 /api/master 的取数、令牌与错误体。

不属于 `run_api_tests.py` 的离线套件（那个把连接换成假的），这里是手动执行的实据脚本：
    .venv\\Scripts\\python tests\\stage2\\api\\probe_api_live.py > result/stage2/a-api/xxx.txt

只做不写库的动作：列表、元数据、令牌、错令牌、非法枚举值、未知动作。
口令从临时文件读，不写进仓库；文件不存在就跳过（他人机器上不可复现属预期）。
"""

from __future__ import annotations

import json
import os
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT))
sys.stdout.reconfigure(encoding="utf-8")

os.environ.setdefault("KFC_DB_SERVER", "localhost")
os.environ.setdefault("KFC_DB_NAME", "KFC_DB")
os.environ.setdefault("KFC_DB_TRUST_CERT", "yes")
os.environ.setdefault("KFC_SECRET_KEY", "probe-only-secret")

from app import create_app  # noqa: E402

PW_FILE = Path(os.environ.get("KFC_PROBE_PW_FILE", r"C:/Users/28137/AppData/Local/Temp/kfc_v10_pw.txt"))
LOGIN = os.environ.get("KFC_PROBE_LOGIN", "test_store_manager")


def show(label: str, res) -> None:
    body = res.get_json(silent=True)
    if isinstance(body, dict) and "rows" in body:
        print("%-38s %s rows=%d first=%s" % (label, res.status_code, body["count"], body["rows"][:1]))
    else:
        print("%-38s %s %s" % (label, res.status_code, json.dumps(body, ensure_ascii=False)))


def main() -> int:
    password = PW_FILE.read_text(encoding="utf-8").strip()
    client = create_app().test_client()

    page = client.post("/login", data={"login": LOGIN, "password": password}, follow_redirects=True)
    print("登录 %s: %s" % (LOGIN, "成功" if "退出登录" in page.get_data(as_text=True) else "失败"))
    if "退出登录" not in page.get_data(as_text=True):
        return 1

    show("GET /api/master/meta", client.get("/api/master/meta"))
    show("GET /api/master/product", client.get("/api/master/product"))
    show("GET /api/master/product?status=ACTIVE", client.get("/api/master/product?status=ACTIVE"))
    show("GET /api/master/product?status=INACTIVE", client.get("/api/master/product?status=INACTIVE"))
    show("GET /api/master/nope", client.get("/api/master/nope"))

    token = client.get("/api/csrf").get_json()["csrf_token"]
    print("GET /api/csrf                          令牌长度 %d" % len(token))

    show(
        "POST 无令牌 product/status",
        client.post("/api/master/product/status", json={"product_id": 1, "status": "ACTIVE"}),
    )
    show(
        "POST 错令牌 product/status",
        client.post(
            "/api/master/product/status",
            json={"product_id": 1, "status": "ACTIVE"},
            headers={"X-CSRF-Token": "deadbeef"},
        ),
    )
    show(
        "POST 合法令牌 + 非法枚举值",
        client.post(
            "/api/master/product/status",
            json={"product_id": 1, "status": "BAD"},
            headers={"X-CSRF-Token": token},
        ),
    )
    show(
        "POST 合法令牌 + 未知动作",
        client.post(
            "/api/master/product/delete",
            json={"product_id": 1},
            headers={"X-CSRF-Token": token},
        ),
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
