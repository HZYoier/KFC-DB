# 第一阶段跨域接口契约

> 版本：2026-09-21
>
> 用途：给 A、B、C 在独立分支上并行实现时提供稳定的对象名、参数名、返回列和事务边界。
>
> 本文档只定义契约，不创建空实现或测试桩。A、C 必须在各自负责的脚本中实现同名对象；B 只能调用，不能复制规则或直接写对方表。

## 1. B 已交付给 C 的稳定对象

`sql/02_order_schema.sql` 创建 B 所有的五张表：

| 表 | C 可依赖的字段 | C 的后续动作 |
| --- | --- | --- |
| `dbo.SalesOrder` | `order_id`、`order_status`、`fulfillment_method`、时间戳 | 库存过程按 `order_id` 关联订单；不得直接改订单状态 |
| `dbo.SalesOrderItem` | `order_id`、`product_id`、`parent_order_item_id`、`item_role`、`quantity` | 锁库/实扣按 `SELLABLE` 单品和 `COMPONENT` 套餐子项展开 BOM |
| `dbo.Payment` | `order_id`、支付状态和金额快照 | C 不写入 |
| `dbo.Delivery` | `order_id`、`rider_employee_id`（可空） | C 在自己的脚本中补骑手外键；未分配骑手时保持可空 |
| `dbo.PointLedger` | `order_id`、`customer_id`、`point_delta`、`ledger_status` | C 不写入 |

C 可以在自己的 schema 脚本中补充 `Delivery.rider_employee_id -> EmployeeAccount.employee_id` 外键。

## 2. A 提供给 B 的接口

### 2.1 成交价函数

```sql
dbo.fn_get_effective_product_price
(
    @product_id BIGINT,
    @at         DATETIME2(0)
)
RETURNS TABLE
(
    product_id      BIGINT,
    effective_price DECIMAL(10,2),
    promotion_id    BIGINT NULL
)
```

约束：

1. 必须是内联表值函数，每次调用恰好返回一行。
2. 无命中促销时返回标准价和 `NULL` 的 `promotion_id`。
3. 促销必须同时满足活动启用、日期、星期及时段条件。
4. 多条规则命中时按 `priority DESC, promotion_rule_id ASC` 取唯一一条。
5. 星期映射使用 `DATEDIFF(DAY, DATEFROMPARTS(1900,1,1), CAST(@at AS DATE)) % 7 + 1`，不能使用受 `DATEFIRST` 影响的 `DATEPART(WEEKDAY, ...)`。
6. B 的 `sp_create_order` 和 A 的 `v_active_product_price` 都调用此函数，不得复制促销判断。

### 2.2 积分入账过程

```sql
dbo.sp_apply_customer_points
    @customer_id BIGINT,
    @delta       INT
```

约束：

1. 只更新 A 所有的 `Customer.current_points` 和 `Customer.member_level_id`。
2. 先以 `UPDLOCK, HOLDLOCK` 锁定顾客，再将积分加到当前已生效积分。
3. 从 `ACTIVE` 的 `MemberLevel` 中选择 `threshold_points <= 更新后积分` 的最高门槛；同门槛取 `member_level_id` 最小者。
4. 不读取、不更新 B 的 `PointLedger`。
5. `@delta` 不得为负；顾客不存在或已停用时必须 `THROW`。
6. 支持嵌套事务：无外层事务时自行提交；有外层事务时只建立保存点，失败回滚到保存点并 `THROW`。

## 3. C 提供给 B 的接口

以下过程名、参数名和参数类型固定。B 的外层事务由 B 持有，C 过程必须支持嵌套调用。

### 3.1 锁定订单库存

```sql
dbo.sp_lock_order_inventory
    @order_id BIGINT
```

- 读取同订单的 `SELLABLE` 单品和 `COMPONENT` 套餐子项，通过 `ProductBom` 汇总原料需求。
- 套餐父项不能直接当作有 BOM 的单品；库存行使用 `UPDLOCK, HOLDLOCK`。
- 成功后增加 `locked_qty`，写 `LOCK` 流水，引用类型为 `ORDER`，引用 ID 为订单 ID。
- 库存不足或订单明细非法时必须抛错，调用方外层事务应整体回滚。

### 3.2 释放订单库存

```sql
dbo.sp_release_order_inventory
    @order_id BIGINT,
    @reason   VARCHAR(20)
```

`@reason` 只允许：`CANCEL`、`PAYMENT_TIMEOUT`、`REFUND`。

- 只能释放尚未实扣的锁定量。
- 写 `RELEASE` 流水：`on_hand_delta = 0`、`locked_delta = -释放量`。
- 已经 `CONSUME` 的订单必须抛错，不能静默加回库存。

### 3.3 实扣订单库存

```sql
dbo.sp_consume_order_inventory
    @order_id BIGINT
```

- 制作完成时调用；同等数量减少 `on_hand_qty` 和 `locked_qty`。
- 写 `CONSUME` 流水：`on_hand_delta = -实扣量`、`locked_delta = -实扣量`。
- 实扣后按 `Ingredient.safety_stock_qty - Inventory.on_hand_qty` 生成或更新补货建议。
- 库存永不得为负。

### 3.4 审计写入

```sql
dbo.sp_write_audit_log
    @employee_id  BIGINT,
    @action_name  VARCHAR(50),
    @entity_name  VARCHAR(50),
    @entity_id    BIGINT,
    @detail_json  NVARCHAR(MAX)
```

- 只写 C 所有的 `AuditLog`，调用方不得直接写审计表。
- 过程内部按 `EmployeeAccount.database_user_name = USER_NAME()` 校验当前激活员工，不能信任伪造的员工 ID。
- 保持 `dbo` 所有权链，使 A/B 通过 `EXECUTE` 调用即可。
- `detail_json` 只记录业务字段，不记录完整支付报文、密码或敏感凭证。

### 3.5 C 自有但一并冻结的收货过程

```sql
dbo.sp_receive_inventory
    @purchase_order_id BIGINT,
    @employee_id       BIGINT
```

该过程不由 B 调用，但名称和参数供 C 的补货验收脚本使用。

## 4. 事务与所有权边界

| 调用方 | 被调用方 | 规则 |
| --- | --- | --- |
| B | A 的定价函数 | 只读，返回成交价快照 |
| B | A 的积分过程 | B 先将 `PointLedger` 从 `PENDING` 改为 `EFFECTIVE`，再调用 A；两者在同一外层事务 |
| B | C 的锁库/释放/实扣过程 | B 持有订单外层事务，C 只用保存点，不提交 B 的事务 |
| B | C 的审计过程 | B 完成取消/退款后调用，失败则整体回滚 |
| A/C | B 的订单表 | 只读或建立外键；不得直接改变订单、支付和积分状态 |

任何一方都不能用直接 `INSERT/UPDATE/DELETE` 绕过另一方的业务过程。

## 5. 接入顺序与当前边界

1. 先执行 A 的 `01_master_schema.sql` 和本目录的 `02_order_schema.sql`。
2. A 按第 2 节创建两个接口和 A 的约束/CRUD。
3. C 按第 3 节创建库存、审计过程，并补 `Delivery.rider_employee_id` 外键。
4. A/C 完成后，再接入 B 的 `05_order_constraints_crud.sql`、视图、种子和验收脚本。

本文档和 `02_order_schema.sql` 是可提前共享的稳定部分；B 的业务过程实现、种子数据和验收脚本仍保留在本地 B 分支，避免未确定的实现先进入远端。
