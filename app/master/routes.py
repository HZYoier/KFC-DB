"""主数据域页面层（店长）：列表页 + 表单动作，一律经 service 到库里的过程。

身份从哪来：员工侧过程按 USER_NAME() 认人，所以每个请求都要用**该员工自己的**数据库登录。
本文件只做读取，不自己造身份，按下列顺序取：
  1. C 的 `app/auth` 提供 `current_employee_session()` 时用它（多人登录的正路）；
  2. 否则看 Flask 会话里有没有 `db_login` / `db_password`（C 的登录页写这两个键即可接入）；
  3. 都没有则回 None，由 `app/common/db.py` 退回 `.env` 里的部署账户——只够本地冒烟，
     库里的岗位守卫会按这个身份判，对不上就是 51004。
无论走哪条，最终判身份的都是数据库，页面不缓存「我是店长」这种结论。
"""

from __future__ import annotations

from flask import Blueprint, redirect, render_template, request, url_for

from app.common.errors import AppError
from app.master import service

bp = Blueprint("master", __name__, url_prefix="/master")

# slug -> 实体码与列标签；列顺序与契约 §2.4.1 一致，模板不做二次裁剪
ENTITIES = {
    "category": {
        "code": "CATEGORY",
        "title": "分类",
        "columns": (("category_id", "ID"), ("category_name", "名称"), ("status", "状态")),
    },
    "product": {
        "code": "PRODUCT",
        "title": "商品",
        "columns": (
            ("product_id", "ID"), ("product_name", "名称"), ("base_price", "标准价"),
            ("product_type", "类型"), ("status", "状态"),
        ),
    },
    "ingredient": {
        "code": "INGREDIENT",
        "title": "原料",
        "columns": (
            ("ingredient_id", "ID"), ("ingredient_name", "名称"), ("unit_name", "单位"),
            ("safety_stock_qty", "安全库存"), ("status", "状态"),
        ),
    },
    "member-level": {
        "code": "MEMBER_LEVEL",
        "title": "会员等级",
        "columns": (
            ("member_level_id", "ID"), ("level_name", "等级名"),
            ("point_multiplier", "积分倍率"), ("threshold_points", "门槛分"), ("status", "状态"),
        ),
    },
    "customer": {
        "code": "CUSTOMER",
        "title": "顾客",
        "columns": (
            ("customer_id", "ID"), ("mobile", "手机号"), ("customer_type", "类型"),
            ("member_level_id", "等级ID"), ("level_name", "等级"), ("current_points", "积分"),
            ("status", "状态"),
        ),
    },
    "bom": {
        "code": "PRODUCT_BOM",
        "title": "商品配方",
        "columns": (
            ("product_id", "商品ID"), ("product_name", "商品"), ("ingredient_id", "原料ID"),
            ("ingredient_name", "原料"), ("usage_qty", "用量"),
        ),
        "status": False,
    },
    "combo": {
        "code": "COMBO",
        "title": "套餐组成",
        "columns": (
            ("combo_product_id", "套餐ID"), ("combo_product_name", "套餐"),
            ("child_product_id", "子项ID"), ("child_product_name", "子项"), ("quantity", "数量"),
        ),
        "status": False,
    },
    "promotion": {
        "code": "PROMOTION",
        "title": "促销活动",
        "columns": (
            ("promotion_id", "ID"), ("promotion_name", "名称"), ("promotion_type", "类型"),
            ("start_at", "开始"), ("end_at", "结束"), ("status", "状态"),
        ),
    },
    "promotion-rule": {
        "code": "PROMOTION_RULE",
        "title": "促销规则",
        "columns": (
            ("promotion_rule_id", "ID"), ("promotion_id", "活动ID"), ("promotion_name", "活动"),
            ("product_id", "商品ID"), ("product_name", "商品"), ("weekday_no", "星期"),
            ("start_time", "开始"), ("end_time", "结束"), ("promo_price", "促销价"),
            ("priority", "优先级"),
        ),
        "status": False,
    },
}

# (slug, action) -> (service 函数, 表单字段名)。字段名必须与 service 的参数名逐字相同，
# 这样表单多写一个字段会被忽略、少写一个会在 service 里按空值挡下，不需要另写映射表。
ACTIONS = {
    ("category", "create"): (service.create_category, ("category_name",)),
    ("category", "status"): (service.update_category_status, ("category_id", "status")),
    ("product", "create"): (
        service.create_product, ("product_name", "base_price", "product_type", "category_id"),
    ),
    ("product", "price"): (service.update_product_price, ("product_id", "base_price")),
    ("product", "status"): (service.update_product_status, ("product_id", "status")),
    ("ingredient", "create"): (
        service.create_ingredient, ("ingredient_name", "unit_name", "safety_stock_qty"),
    ),
    ("ingredient", "update"): (
        service.update_ingredient,
        ("ingredient_id", "ingredient_name", "unit_name", "safety_stock_qty", "status"),
    ),
    ("member-level", "create"): (
        service.create_member_level, ("level_name", "point_multiplier", "threshold_points"),
    ),
    ("member-level", "update"): (
        service.update_member_level,
        ("member_level_id", "level_name", "point_multiplier", "threshold_points"),
    ),
    ("member-level", "status"): (service.update_member_level_status, ("member_level_id", "status")),
    ("customer", "create"): (service.create_customer, ("mobile", "customer_type")),
    ("customer", "level"): (
        service.update_customer_member_level, ("customer_id", "member_level_id"),
    ),
    ("promotion", "create"): (
        service.create_promotion, ("promotion_name", "promotion_type", "start_at", "end_at"),
    ),
    ("promotion", "status"): (service.update_promotion_status, ("promotion_id", "status")),
    ("promotion-rule", "create"): (
        service.add_promotion_product_rule,
        ("promotion_id", "product_id", "weekday_no", "start_time", "end_time",
         "promo_price", "priority"),
    ),
    ("promotion-rule", "update"): (
        service.update_promotion_product_rule,
        ("promotion_rule_id", "weekday_no", "start_time", "end_time", "promo_price", "priority"),
    ),
    ("bom", "set"): (service.set_product_bom, ("product_id", "lines")),
    ("combo", "set"): (service.set_combo_component, ("product_id", "lines")),
}


def current_session():
    """按模块文档的三级顺序取员工身份；只读，不缓存。"""
    try:
        from app.auth import current_employee_session  # 由 C 的登录层提供，未就位时跳过
    except ImportError:
        current_employee_session = None
    if current_employee_session is not None:
        return current_employee_session()

    from flask import session as flask_session

    if flask_session.get("db_login"):
        return {
            "db_login": flask_session.get("db_login"),
            "db_password": flask_session.get("db_password"),
        }
    return None


@bp.context_processor
def _shared():
    """导航在每个页面上都要有；实体表只在路由里定义一份，模板不重复抄。"""
    return {"entities": ENTITIES}


def _notice():
    if request.args.get("ok"):
        return ("ok", "已提交")
    return None


@bp.get("/")
def index():
    return render_template("master/index.html", notice=_notice())


@bp.get("/<entity>")
def list_view(entity: str):
    meta = ENTITIES.get(entity)
    if meta is None:
        return render_template("master/not_found.html", entity=entity), 404

    status = None
    if meta.get("status", True):
        status = request.args.get("status") or None

    rows, error = [], None
    try:
        rows = service.list_master_records(current_session(), meta["code"], status)
    except AppError as err:
        # 页面层只负责把错误码映射成提示，不重试、不改判
        error = err.user_message
    return render_template(
        "master/list.html",
        entity=entity,
        meta=meta,
        rows=rows,
        status=status,
        error=error,
        notice=_notice(),
    )


@bp.post("/<entity>/<action>")
def do_action(entity: str, action: str):
    spec = ACTIONS.get((entity, action))
    if spec is None or entity not in ENTITIES:
        return render_template("master/not_found.html", entity=entity), 404

    handler, fields = spec
    try:
        handler(current_session(), **{name: request.form.get(name) for name in fields})
    except AppError as err:
        meta = ENTITIES[entity]
        try:
            rows = service.list_master_records(current_session(), meta["code"])
        except AppError:
            rows = []
        return (
            render_template(
                "master/list.html",
                entity=entity,
                meta=meta,
                rows=rows,
                status=None,
                error=err.user_message,
                notice=None,
            ),
            err.http_status,
        )
    return redirect(url_for("master.list_view", entity=entity, ok=1))
