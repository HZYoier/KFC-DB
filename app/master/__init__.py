"""主数据域（A）：routes / service / dao / templates。

蓝图在这里导出，`app/__init__.py` 按 `BLUEPRINT_MODULES` 自动注册，不需要改工厂。
列表只经 `sp_list_master_records`（契约 §2.4.1），写入只经 `04` 的十八个自持事务过程——
主数据页不读基表，也不替数据库判断唯一键、状态机与定价规则。
"""

from app.master.routes import bp

__all__ = ["bp"]
