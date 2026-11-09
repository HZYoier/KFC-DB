"""`/api/master` 路由：与页面共用同一张 ENTITIES / ACTIONS 表，不另写一份映射。

入参一律先转成表单同形的字符串再交给 service——service 的校验器本来就是按字符串写的，
接口层不重写一遍。配方 / 套餐子项在页面上是「每行一条 id 数量」的文本框，接口收 JSON
数组后转回同一形状，service 只保留一种入参。
"""

from __future__ import annotations

from flask import jsonify, request

from app.api import bp
from app.common.csrf import require as require_csrf
from app.common.csrf import token as csrf_token
from app.common.db import jsonable
from app.common.errors import AppError
from app.master import service
from app.master.routes import ACTIONS, ENTITIES, current_session


# 配方 / 套餐子项在页面上是「每行一条 id 数量」的文本框，service 按这个形状校验。
# 接口侧收 JSON 数组，这里转回同一形状，别让 service 出现第二种入参。
_LINE_FIELDS = {
    ("bom", "set"): ("ingredient_id", "usage_qty"),
    ("combo", "set"): ("child_product_id", "quantity"),
}


def _value(value):
    """JSON 标量 -> 表单同形的字符串（service 的校验器按字符串写）。"""
    if value is None:
        return None
    if isinstance(value, (list, dict)):
        raise AppError("E_INPUT")
    return str(value)


def _lines_text(items, id_key: str, value_key: str) -> str:
    """JSON 数组 -> 「id 数量」逐行文本；已经是字符串的原样交给 service 校验。"""
    if isinstance(items, str):
        return items
    if not isinstance(items, list):
        raise AppError("E_INPUT")
    lines = []
    for item in items:
        if not isinstance(item, dict) or id_key not in item or value_key not in item:
            raise AppError("E_INPUT")
        lines.append("%s %s" % (item[id_key], item[value_key]))
    return "\n".join(lines)


@bp.get("/csrf")
def csrf():
    return jsonify({"csrf_token": csrf_token()})


@bp.get("/master/meta")
def master_meta():
    return jsonify(
        {
            "entities": [
                {
                    "slug": slug,
                    "code": item["code"],
                    "title": item["title"],
                    "columns": [list(column) for column in item["columns"]],
                    "filterable_by_status": item.get("status", True),
                }
                for slug, item in ENTITIES.items()
            ],
            "actions": [
                {"entity": entity, "action": action, "fields": list(fields)}
                for (entity, action), (_, fields) in sorted(ACTIONS.items())
            ],
        }
    )


@bp.get("/master/<entity>")
def master_list(entity: str):
    spec = ENTITIES.get(entity)
    if spec is None:
        raise AppError("E_NOTFOUND")
    status = (request.args.get("status") or None) if spec.get("status", True) else None
    rows = jsonable(service.list_master_records(current_session(), spec["code"], status))
    return jsonify(
        {
            "entity": entity,
            "code": spec["code"],
            "status": status,
            "count": len(rows),
            "columns": [list(column) for column in spec["columns"]],
            "rows": rows,
        }
    )


@bp.post("/master/<entity>/<action>")
def master_write(entity: str, action: str):
    require_csrf()
    if entity not in ENTITIES:
        raise AppError("E_NOTFOUND")
    spec = ACTIONS.get((entity, action))
    if spec is None:
        raise AppError("E_NOTFOUND")

    payload = request.get_json(silent=True)
    if not isinstance(payload, dict):
        raise AppError("E_INPUT")

    handler, fields = spec
    values = {}
    for name in fields:
        if name == "lines" and (entity, action) in _LINE_FIELDS:
            values[name] = _lines_text(payload.get(name), *_LINE_FIELDS[(entity, action)])
        else:
            values[name] = _value(payload.get(name))
    handler(current_session(), **values)
    return jsonify({"ok": True, "entity": entity, "action": action, "message": "已提交"})
