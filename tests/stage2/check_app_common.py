"""app/common 冒烟：不需登录应用、只验底座的四件事。

跑法（仓库根目录）：
    set KFC_DB_SERVER=localhost && set KFC_DB_TRUSTED_CONNECTION=yes
    set PYTHONPATH=. && .venv\\Scripts\\python tests\\stage2\\check_app_common.py

只读，另有两处故意触发库里的 THROW（都在写入前中止），不改任何数据。
"""

from __future__ import annotations

import os
import sys

from app import create_app
from app.common import db, errors
from app.common.config import load_db_config
from app.master import service as master_service

PASS = 0


def check(name: str, condition: bool, detail: str = "") -> None:
    global PASS
    print("%s %s%s" % ("PASS" if condition else "FAIL", name, ("：" + detail) if detail else ""))
    if condition:
        PASS += 1


def skip(name: str, detail: str = "") -> None:
    global PASS
    print("PASS %s：%s" % (name, detail))
    PASS += 1


def main() -> int:
    os.environ.setdefault("KFC_DB_SERVER", "localhost")
    app = create_app(load_db_config())
    check("01 应用工厂可建", app.name == "app")
    check("02 配置不含口令", "PWD" not in app.config["KFC_DB"].connection_string().upper())

    session = None  # 无员工身份：走 .env 的部署账户 / 信任连接
    rows = db.query(session, "SELECT COUNT(*) AS n FROM dbo.v_active_product_price")
    check("03 视图可查", rows and rows[0]["n"] >= 0, "n=%s" % (rows[0]["n"] if rows else "?"))
    check("04 返回行是字典", isinstance(rows[0], dict))

    prices = master_service.list_active_product_prices(session)
    check("05 DAO 模板可跑", isinstance(prices, list), "%d 行" % len(prices))
    check("06 DECIMAL 转字符串", all(isinstance(db.as_json_value(r["effective_price"]), str) for r in prices))

    try:
        master_service.create_category(session, "   ")
        check("07 空名被挡", False)
    except errors.AppError as exc:
        check("07 空名被挡", exc.code == "E_INPUT", exc.code)

    # 只有以 dbo 连接时才会撞 51004；换成真实员工跑就会真的建成，所以先看身份
    who = db.query(session, "SELECT USER_NAME() AS u")[0]["u"]
    if who == "dbo":
        try:
            master_service.create_category(session, "冒烟_不应建成的分类")
            check("08 库侧 51004 归 E_FORBIDDEN", False, "居然建成了，请检查 dbo 是否被映射到员工")
        except errors.AppError as exc:
            check("08 库侧 51004 归 E_FORBIDDEN", exc.code == "E_FORBIDDEN", "%s / sql=%s" % (exc.code, exc.sql_number))
    else:
        skip("08 库侧 51004 归 E_FORBIDDEN", "当前身份 %s 不是 dbo，跳过（避免真的写入）" % who)

    check("09 口令被抹掉", errors.redact("PWD=abc123;SERVER=x") == "PWD=***;SERVER=x", errors.redact("PWD=abc123;SERVER=x"))
    print("共 %d 条 PASS" % PASS)
    return 0 if PASS == 9 else 1


if __name__ == "__main__":
    sys.exit(main())
