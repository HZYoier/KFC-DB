# 成员 A 第一阶段报告：主数据、定价与会员

> 成员 A：24325106 胡志远

## 1. 阶段目标

成员 A 负责把“品类 / 商品与套餐 / 原料与 BOM / 促销 / 会员等级 / 顾客”落成一套可建库、可约束、可查询、可复现验收的关系数据库实现，并向 B 提供成交价与积分入账两个跨域接口、向 C 提供原料、安全库存线与 BOM，使订单域能凭 A 的种子 ID 直接下单、库存域能凭 BOM 算出用料。

## 2. 实验思路

本实验采用“关系约束 + 定价单点 + 入口拦截 + 成对断言”的方法：

1. 静态合法性交给 22 条命名 `CHECK`、9 条外键与 2 个唯一索引；枚举取值的唯一权威是命名 `CHECK`，`01` 的注释与数据字典都跟随它，不在三处各写一份取值自相矛盾。
2. 受 `CHECK` 约束的列一律显式 `NOT NULL`：`CHECK` 的表达式在 `NULL` 上求值为 `UNKNOWN` 会直接放行，列可空等于绕过全部取值与数值约束。`01` 里唯一的可空列是 `Customer.member_level_id`，含义是“等级被停用而置空”。
3. 定价只实现一处：促销的活动启用、日期、星期、时段四重匹配全部收进内联表值函数 `fn_get_effective_product_price`，视图与 B 的 `sp_create_order` 都调用它，不复制判断；星期映射用 `DATEDIFF`，不用受 `DATEFIRST` 影响的 `DATEPART(WEEKDAY, ...)`。
4. 入口拦截优先于事后校验：单品没有用料、套餐有子项缺 BOM，一律不许置 `ACTIVE`；建档时定位不到默认会员等级就 `THROW`，而不是建出一个付不了款的顾客。
5. 跨域只经两个冻结接口：`fn_get_effective_product_price`（读）与 `sp_apply_customer_points`（写）。后者只动 A 的 `Customer`、不碰 B 的 `PointLedger`，先 `UPDLOCK, HOLDLOCK` 锁顾客，并区分“无外层事务自行提交 / 有外层事务只建保存点”。
6. 种子 ID 用显式 `IDENTITY_INSERT` 固定并写进契约第 6 节供 B、C 直接引用；`09a` 只允许在空库上执行（守卫 `THROW 51000`），种子常量若变动先通知。
7. 验收 13 条按“反例 → 对照”成对设计，末批用分母守卫（跨批次的 `#a10_assertion` 少于 13 即 `THROW`）抓“某批被静默作废”。

## 3. A 域交付物

### 3.1 关系表（10 张）

`Category`、`MemberLevel`、`Ingredient`、`Product`、`ProductCategory`、`Customer`、`ProductBom`、`ComboComponent`、`Promotion`、`PromotionProductRule`。10 张表均带主键；`ProductCategory`、`ProductBom`、`ComboComponent` 用复合主键，不另设无意义的代理键；`Customer.mobile` 建唯一约束，`ProductCategory` 另建过滤唯一索引 `UQ_ProductCategory_is_primary`，保证每个商品至多一个展示分类。

### 3.2 业务过程（18 个 CRUD + 2 个接口对象）

- 分类与原料：`sp_create_category`、`sp_update_category_status`、`sp_create_ingredient`、`sp_update_ingredient`；
- 商品与套餐：`sp_create_product`、`sp_update_product_price`、`sp_update_product_status`、`sp_set_product_bom`、`sp_set_combo_component`；
- 促销：`sp_create_promotion`、`sp_update_promotion_status`、`sp_add_promotion_product_rule`、`sp_update_promotion_product_rule`；
- 会员：`sp_create_member_level`、`sp_update_member_level`、`sp_update_member_level_status`、`sp_create_customer`、`sp_update_customer_member_level`；
- 跨域接口对象：`fn_get_effective_product_price`、`sp_apply_customer_points`。

所有写过程按 `EmployeeAccount.database_user_name = USER_NAME()` 解析 `ACTIVE` 员工，解析不到即拒绝执行，不信任外部传入的主体参数；计划 A-2 点名范围（商品价格、BOM、套餐组成、促销规则、会员等级）内的 11 处在成功后调用 C 的 `sp_write_audit_log`。

### 3.3 查询与视图（`07a_master_views_queries.sql`）

两个视图：`v_active_product_price`（在售商品、展示分类、标准价、当前成交价与生效促销 ID，内部调用定价函数）、`v_product_bom_detail`（单品直连 `ProductBom`；套餐经 `ComboComponent → ProductBom` 展开并按套餐与原料汇总用量）。两条具名查询：`-- Q-A1 在售商品及当前售价`、`-- Q-A2 指定商品的 BOM 明细`（以 `@product_id` 变量演示用法）。

### 3.4 约束与种子（`04`、`09a`）

22 条命名 `CHECK`：数值 9 条（`base_price > 0`、`usage_qty > 0`、`quantity > 0`、`promo_price > 0`、`safety_stock_qty >= 0`、`priority >= 0`、`threshold_points >= 0`、`current_points >= 0`、`point_multiplier > 0`）、时间序 2 条（`Promotion.end_at > start_at`、`PromotionProductRule.end_time > start_time`）、星期号 1 条（`weekday_no BETWEEN 1 AND 7`）、状态枚举 6 条、类型枚举 3 条（`product_type` / `customer_type` / `promotion_type`）、手机号格式 1 条（真实号 11 位纯数字；游客临时号为 `TEMP-` 加 11 位）。

`09a` 插入 2 个分类、6 个商品（含 1 个套餐）、8 条商品×分类关系、6 种原料、12 行 BOM、3 行套餐组成、3 个会员等级、3 位顾客、1 个周四 9.9 元促销及 2 条规则；套餐只配 `ComboComponent`，不在 `ProductBom` 留行。

## 4. 实验环境

| 项目 | 值 |
| --- | --- |
| 日期 | 2026-10-03 |
| SQL Server | 17.0.1000.7，Express Edition (64-bit)，兼容级别 170 |
| 实例 | `localhost`（`@@SERVERNAME` = `DESKTOP-TSLV34Q`），默认实例 |
| 认证 | Windows 身份验证 |
| 工具 | `sqlcmd` + ODBC Driver 18；执行一律带 `-C -f 65001 -b` |

执行命令（仓库根目录，执行前确认 `KFC_DB` 不存在）：

```bat
sqlcmd -S localhost -E -N o -C -f 65001 -b -i sql/run_all.sql
```

## 5. 实验过程

### 5.1 空库部署与整链验收

从空库只执行唯一入口，18 个文件按固定顺序一次部署完成：`exit=0`、0 条错误消息；三条验收 `RESULT` 为 A `13/13`、B `15/15`、C `18/18`，加 B 的种子自检共 47 条 `PASS:`；只读接口检查器 `sql/contract_interface_check.sql` 返回 `PASS`。部署后清点 A 域对象：10 张表（均含主键）、22 条 `CHECK`、9 条外键、2 个唯一索引、19 个过程加 1 个内联表值函数、2 个视图、2 条具名查询。

### 5.2 定价与促销匹配

`v_active_product_price` 与定价函数对同一时刻返回同一价格与同一促销 ID（A8）；重叠促销按 `priority DESC, promotion_rule_id ASC` 取唯一最高优先级（A7，用固定周四 `2026-10-01 12:00` 与周六 `2026-10-03 12:00` 两个时刻对照，避免断言退化成标准价）；促销结束早于开始被拒（A5，参数校验 `51000`），起止合法时可建且建档即 `INACTIVE`（A6）。日期层是闭区间、时间层是半开区间，周四用 `weekday_no = 4` 表达，与部署当天是星期几无关。

### 5.3 上架拦截与 BOM 视图

无任何用料的单品不能上架（A9，`51003`），有 BOM 的单品可以（A10）；套餐存在没有 BOM 的子项时不能上架（A11，第三道门 `51003`）。BOM 视图两个分支都验：单品分支的“用料商品即商品自身”（A12）；套餐分支经子商品展开、用量按子项数量缩放、跨子项合计正确（A13，套餐 5 = 香辣鸡腿堡×1 + 劲脆鸡腿堡×1 + 可乐(中)×2，行粒度必须是 9 行 3 子商品，且每子商品行不得被跨子项汇总）。

### 5.4 事务与失败路径

`run_all.sql` 是单会话执行，`02_order_schema.sql:15` 的批次级 `SET XACT_ABORT ON` 会一直留到 `10a`；此时过程内的 `THROW` 会把外层事务打成不可提交（`XACT_STATE() = -1`），而 `REVERT` 在不可提交事务里被拒（Msg 3930）并中止整批，把原始错误盖掉。`10a` 的 5 个反例（A1/A3/A5/A9/A11）统一改为在 `CATCH` 里先 `IF XACT_STATE() = -1 ROLLBACK TRANSACTION;` 再 `REVERT`；4 个对照断言（A2/A4/A6/A10）的读回在事务内进行，因此不能提前回滚，否则读回会一起丢掉。

其余反例与边界：重复手机号建档被拒（A1，预检 `51005`），换新号可建档且初始积分为 0、等级取默认档（A2）；负数价格被拒（A3，`51000`），正数价格可改且确实落库（A4）。所有断言各自成批、事务包裹一律回滚，夹具不留在库里。

### 5.5 跨域联调与接口

- 契约第 2.1 节的 6 条约束（内联表值函数每次恰返一行、未命中返标准价与 `NULL` 促销 ID、四重促销条件、按优先级取唯一、`DATEDIFF` 星期映射、视图与 B 不得复制促销判断）与第 2.2 节的 6 条约束（只动 `Customer`、`UPDLOCK, HOLDLOCK` 锁顾客、门槛取最高档同门槛取最小 `member_level_id`、不读写 `PointLedger`、`@delta` 非负、嵌套事务建保存点）全部落地。
- 授权边界：`08` 把 A 的 18 个 CRUD 过程授予 `role_store_manager`；`fn_get_effective_product_price` 与 `sp_apply_customer_points` **不进入授权白名单**，由 `dbo` 所有权链支撑 B 的过程调用，`10a` 的 A7/A8 在 `dbo` 上下文直接调用。A 不建数据库角色、不授任何表级权限。
- 种子常量：ID 与数值、压线原料 `ingredient_id = 5`、促销按 `weekday_no` 生效、手机号号段、套餐不配直接 BOM、建档即带默认等级，均写进契约第 6 节并随 `09a` 冻结。
- 跨域前置：`10a` 依赖 `09c` 为 `test_store_manager` 插入一条 `ACTIVE` 的 `EmployeeAccount` 行，缺行时 `THROW 51900` 并在文案里点名 `09c`。
- 契约第 8 节里由 A 提出并已确认的两项：定价函数 `@at` 按元数据冻结为 `datetime2(0)`、`max_length = 6`（B 已改检查器）；支付过程的 52205 守卫在“建档即带默认等级”口径下保留，B 已加独立反例。
- 断言分工：改商品价不影响历史订单快照、无 BOM 单品不能下单、B 能拿 A 的种子 ID 开出订单三条归 B 的 `10b`；A 只负责“不能上架”这一侧（A9/A11）。

### 5.6 种子与文档

`09a` 的守卫检查全部 10 张 A 域表，任一非空即 `THROW 51000`，因此可重复部署但不会覆盖已验收数据；收尾自查打印商品数、套餐组成行数、BOM 行数与在售促销数。字段级权威是 `docs/主数据数据字典.md`，含逐字段的中文含义、类型、可空、默认值、主外键、取值范围与来源文档段落，第 11 节记录各项设计口径的确认过程与结论。

## 6. 实验结果

| 项目 | 结果 |
| --- | --- |
| 空库整链部署 | `exit=0`，0 条错误消息 |
| A 域验收 | `pass=13 fail=0`（A1–A13） |
| 三域验收 | A `13` / B `15` / C `18`，加种子自检共 47 条 `PASS` |
| A 域对象清点 | 10 表（均含主键）/ 22 `CHECK` / 9 外键 / 2 唯一索引 / 19 过程 + 1 函数 / 2 视图 / 2 具名查询 |
| A 域种子 | 2 分类 / 6 商品（含 1 套餐）/ 8 条分类关系 / 6 原料 / 12 行 BOM / 3 行套餐组成 / 3 等级 / 3 顾客 / 1 促销 + 2 规则 |
| 跨域接口 | 契约检查器 `PASS`（含 `@at` 的 `datetime2(0)`、`max_length = 6` 断言） |


### 6.1 操作截图（2026-10-04）

下列 19 张截图均在 `localhost` 默认实例的 `KFC_DB` 上取得，全部位于 `result/`。其中 18 张是在 SSMS 里逐条执行所得；建库那一张取自 `sqlcmd -o` 写出的 UTF-8 日志（直接打在控制台会因代码页 936 而乱码，写文件再打开才能正常显示）。写操作一律包在 `BEGIN TRANSACTION … ROLLBACK` 内，夹具不留在库里；CRUD 五张另配"改前 / 改后"两次读回与 `ROLLBACK` 同屏，因此截图中的行号跳号（如新建分类拿到 `category_id = 4`）是回滚消费的 identity，非脏数据。

| 类别 | 截图 | 内容 |
| --- | --- | --- |
| 建库 | `stage1-a-create-database-2026-10-04.png` | 删库后从空库整跑 `run_all.sql`，日志开头即 `KFC_DB 创建完成，兼容级别 = 170`。同轮完整日志为 `result/stage1-full-test-a-2026-10-04.txt`（`exit=0`、47 条 `PASS`、0 条错误），与 `2026-10-03` 那份逐字节相同 |
| CRUD | `stage1-a-crud-create-category-2026-10-04.png` | 建分类：`Category` 2 行 → 3 行 |
| CRUD | `stage1-a-crud-update-price-2026-10-04.png` | 改商品价：香辣鸡腿堡 19.00 → 21.00 |
| CRUD | `stage1-a-crud-set-bom-2026-10-04.png` | 改配方：薯条(中) 用量 150.000 → 160.000 |
| CRUD | `stage1-a-crud-set-combo-component-2026-10-04.png` | 改套餐组成：`ComboComponent` 3 行 → 2 行 |
| CRUD | `stage1-a-crud-create-promotion-2026-10-04.png` | 建促销：`Promotion` 1 行 → 2 行，新行建档即 `INACTIVE` |
| 关键查询 | `stage1-a-pricing-view-vs-function-2026-10-04.png` | 视图按当前时刻（执行日非周四）无促销、价格等于标准价；定价函数取固定周四 `2026-10-01 12:00` 得 `effective_price = 9.90`、`promotion_id = 1`，验证星期与时段匹配真实生效 |
| 关键查询 | `stage1-a-query-q-a2-bom-single-2026-10-04.png` | Q-A2 单品分支：香辣鸡腿堡 4 行用料 |
| 关键查询 | `stage1-a-query-q-a2-bom-combo-2026-10-04.png` | Q-A2 套餐分支：双人分享餐 9 行、3 个子商品，可乐原浆按子项数量缩放为 600.000 |
| 视图 | `stage1-a-views-2026-10-04.png` | 两个视图本体 |
| 越权访问 | `stage1-a-denied-select-category-2026-10-04.png` | 店长直接读表被拒：`消息 229`（有过程执行权、无表读权） |
| 越权访问 | `stage1-a-reject-51004-unmapped-principal-2026-10-04.png` | 有对象权限但未映射到启用员工：`51004` |
| 非法数据 | `stage1-a-reject-51000-negative-price-2026-10-04.png` | 负数价格：`51000` |
| 非法数据 | `stage1-a-reject-51005-duplicate-mobile-2026-10-04.png` | 重复手机号：`51005` |
| 非法数据 | `stage1-a-reject-51003-activate-without-bom-2026-10-04.png` | 无用料单品不能上架：建档（即 `ACTIVE`）→ 下架 → 再上架，第三道门 `51003` |
| 非法数据 | `stage1-a-reject-51003-bom-on-combo-2026-10-04.png` | 套餐不能配直接 BOM：`51003` |
| 非法数据 | `stage1-a-reject-547-check-constraint-2026-10-04.png` | 绕过存储过程直写撞原生约束：`547`×3（`CK_Product_base_price` / `CK_Product_status` / `CK_Product_product_type`）+ `2627`（`UQ_Customer_Mobile`）。这四条 `INSERT` 在约束处即被拒、零写入，`ROLLBACK` 只是双保险；它的意义在于证明过程自查之外的原生约束确实在拦——`10a` 的 13 条断言全部走存储过程，先由过程 `THROW 51xxx`，约束本身本不会被触发 |
| 对象清点 | `stage1-a-object-inventory-2026-10-04.png` | 表 25 / 有主键的表 25 / 外键 35 / `CHECK` 51 / 过程 42 / 视图 10 / 业务角色 7 / 表级 `DENY` 21 |
| 角色权限 | `stage1-a-permission-matrix-2026-10-04.png` | A 域对象授权全景：只有 `role_store_manager` 持有过程的 `EXECUTE`；`Customer` 的 `UPDATE` 对 7 个业务角色全为 `DENY` |



## 7. 实验结论

主数据域不仅能独立表达品类、商品、套餐、原料与 BOM、促销和会员关系，也能让 B 凭冻结的种子 ID 直接下单、让 C 凭 BOM 算出订单用料；定价判断只有一处实现，视图与订单过程共用同一函数，不存在两套促销规则漂移的可能。13 条断言把“反例被拒”与“合法路径确实落库”成对验证，失败路径的收尾事务顺序也已固定为可重复执行的写法。

