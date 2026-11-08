# A 主数据页面截图（2026-11-08）

> 属主：A（主数据、定价、会员）。本目录只放 A 域页面的运行截图与环境说明，不是 v1.0 全链路验收证据。

## 环境

- 实例：`localhost`（SQL Server 2025 Express 17.0.1000.7，Windows 身份部署）。
- 库：`KFC_DB_DEMO`，由本机 `KFC_DB`（v0.1：25 表 / 42 过程 / 3 行顾客）`BACKUP` + `RESTORE ... WITH MOVE` 复制，随后只执行 **`11a` + `11c`**。
- **未执行 `11b`**：B 的迁移脚本尚未交付（OI-18），`run_migration.sql` 的 53513 现要求 15 个过程，缺 `11b` 会在该处失败。
- **未执行 `12_permissions`**：`12` 里有针对 B 七个过程的 `GRANT`，过程不存在时会失败；属于 A 的授权按 `12` 的口径手工补：
  - `sp_list_master_records` → `role_store_manager`
  - `sp_list_sale_products` / `sp_find_customer_for_order` / `sp_register_customer_for_order` → `role_cashier`
  - `sp_get_current_employee_context` → 七个业务角色
  - `sp_list_employee_roles` → `role_store_manager`
  - `sp_customer_register` 仍只授 `cust_app`，未给员工角色（契约 §1.2 约束 6）。
- 演示账号：`demo_manager`（`STORE_MANAGER`，`EmployeeAccount.employee_id = 9`）。口令由脚本随机生成，只存在于本机临时文件，不写入仓库；`sp_get_current_employee_context` 用该登录实测返回 `(9, demo_manager, 演示店长, STORE_MANAGER)`。
- 截图方式：用 Flask test client 以上述账号登录，逐页 `GET` 后保存 HTML（模板自带内联样式，无外部静态资源），再用 Edge headless 以 1360×900 渲染成 PNG。页面里的数据是 `KFC_DB_DEMO` 的真实行，不是桩数据。

## 边界

- 这组截图证明的是：A 的九个主数据实体页在 `11a` + `11c` 的库上、以店长身份可取数与渲染；**不证明** `run_migration` / `regression` / `13c` 的完整验收——那需要 B 的 `11b` 到位后在真实链路上重跑。
- 订单、支付、配餐、配送与顾客端下单/查单页面未交付，截图里没有这些页面。
- `11a` 全文件在外层事务里执行并回滚的核验见 `docs/stage2/a-stage2-report.md` §8。

## 文件

| 文件 | 页面 |
| --- | --- |
| `a-master-ui-01-login-2026-11-08.png` | 员工登录（未填写口令） |
| `a-master-ui-02-identity-2026-11-08.png` | 我的身份（`sp_get_current_employee_context`） |
| `a-master-ui-03-master-index-2026-11-08.png` | 主数据总览（九实体卡片） |
| `a-master-ui-04-category-2026-11-08.png` | 分类 |
| `a-master-ui-05-product-2026-11-08.png` | 商品（列表 + 新建/改价/改状态） |
| `a-master-ui-06-ingredient-2026-11-08.png` | 原料 |
| `a-master-ui-07-member-level-2026-11-08.png` | 会员等级 |
| `a-master-ui-08-customer-2026-11-08.png` | 顾客（列表 + 建档/改等级） |
| `a-master-ui-09-bom-2026-11-08.png` | 商品配方 |
| `a-master-ui-10-combo-2026-11-08.png` | 套餐组成 |
| `a-master-ui-11-promotion-2026-11-08.png` | 促销活动 |
| `a-master-ui-12-promotion-rule-2026-11-08.png` | 促销规则 |
