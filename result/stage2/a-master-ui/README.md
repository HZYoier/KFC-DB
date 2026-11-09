# A 主数据页面截图（2026-11-08，01/02 于 2026-11-09 重截）

> 属主：A（主数据、定价、会员）。本目录只放 A 域页面的运行截图与环境说明，不是 v1.0 全链路验收证据。

## 环境

- 实例：`localhost`（SQL Server 2025 Express 17.0.1000.7，Windows 身份部署）。
- 库：`KFC_DB_DEMO`，由本机 `KFC_DB`（v0.1：25 表 / 42 过程 / 3 行顾客）`BACKUP` + `RESTORE ... WITH MOVE` 复制，随后只执行 **`11a` + `11c`**。
- **未执行 `11b`**：本演示库建库时 B 的 `11b_order_migration.sql` 尚未交付（OI-18，已于 2026-11-09 由 B 交付、C 验收关闭），因此仍是只含 A/C 两域的库；`run_migration.sql` 的 53513 要求 15 个过程齐备，本库不走迁移链，完整 v1.0 链路的证据在 `result/stage2/c-real-migration-2026-11-09.txt`。
- **未执行 `12_permissions`**：`12` 第 2 节有 7 条 `GRANT` 指向 B 的 6 个员工侧订单/配餐/配送过程，过程不存在时会失败（顾客三条在 `12` 里本就是“存在才授”，缺了只打警告，不构成阻碍）；属于 A 的授权按 `12` 的口径手工补：
  - `sp_list_master_records` → `role_store_manager`
  - `sp_list_sale_products` / `sp_find_customer_for_order` / `sp_register_customer_for_order` → `role_cashier`
  - `sp_get_current_employee_context` → 七个业务角色
  - `sp_list_employee_roles` → `role_store_manager`
  - `sp_customer_register` 仍只授 `cust_app`，未给员工角色（契约 §1.2 约束 6）。
- 演示账号：`demo_manager`（`STORE_MANAGER`，`EmployeeAccount.employee_id = 9`）。口令由脚本随机生成，只存在于本机临时文件，不写入仓库；`sp_get_current_employee_context` 用该登录实测返回 `(9, demo_manager, 演示店长, STORE_MANAGER)`。
- 截图方式：用 Flask test client 以上述账号登录，逐页 `GET` 后保存 HTML（模板自带内联样式，无外部静态资源），再用 Edge headless 以 1360×900 渲染成 PNG。页面里的数据是 `KFC_DB_DEMO` 的真实行，不是桩数据。
- **`01`/`02` 于 2026-11-09 重截**：C 在 `app/templates/auth/login.html` 加了「顾客自助」入口，在 `app/templates/auth/index.html` 按岗位显示「库存与补货」「订单工作台」，两页可见内容因此变化，故在同一演示库、同一账号下重截。其余 10 页是 A 域主数据页，模板与数据均未变，仍是 2026-11-08 的原图。身份页显示「没有 ACTIVE 业务角色 / 权限码（0）」是演示库未执行 `12` 的预期结果，与页面模板无关。

## 边界

- 这组截图证明的是：A 的九个主数据实体页在 `11a` + `11c` 的库上、以店长身份可取数与渲染；**不证明** `run_migration` / `regression` / `13c` 的完整验收——那需要 B 的 `11b` 到位后在真实链路上重跑。
- 订单、支付、配餐、配送与顾客端下单/查单页面未交付，截图里没有这些页面。
- `11a` 全文件在外层事务里执行并回滚的核验见 `docs/stage2/a-stage2-report.md` §8。

## 文件

| 文件 | 页面 |
| --- | --- |
| `a-master-ui-01-login-2026-11-09.png` | 员工登录（未填写口令，含「顾客自助」入口；2026-11-09 重截） |
| `a-master-ui-02-identity-2026-11-09.png` | 我的身份（`sp_get_current_employee_context`，含岗位对应的库存/订单入口；2026-11-09 重截） |
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
