# B 数据库接口交接清单

> B；2026-10-14；输入提交 `11bca75`。当前接口按第一阶段源码记录，新增查询为 B 提案，不是已存在对象或已冻结契约。
> A 收取本材料统一写 application-contract，C 审核身份/白名单/GRANT；本文件不直接修改其产物。依据：[计划 §6](../stage2-three-person-implementation-plan.md)、[事务规范](transaction-boundaries.md)。

## 1. 当前写接口：准确签名

通用：无 OUTPUT 参数、无业务结果集；SELECT 主要为内部赋值，不可把内部查询当返回契约。没有显式业务 RETURN 值可供调用者识别新订单；受 NOCOUNT 影响的 ExecuteNonQuery 行数不能作为成功判据。正常完成表示过程未抛错；若使用外层事务，业务最终成功还要求外层提交。断线/超时视为结果未知。

| 过程 | 仅允许的业务岗位 | 变更结果 |
| --- | --- | --- |
| sp_create_order | CASHIER | 订单、价格/组件快照、总额、库存锁 |
| sp_pay_order | CASHIER | 支付、PAID、PENDING 积分 |
| sp_start_production | CHEF | IN_PRODUCTION 与开始时间 |
| sp_finish_production | PACKER | 实扣、待取/待配送、外送 WAITING_PICKUP |
| sp_pick_up_order | PACKER | PICKED_UP、积分生效及顾客入账 |
| sp_pick_up_delivery | RIDER | 认领与 DELIVERING |
| sp_confirm_delivery | RIDER | COMPLETED/DELIVERED、积分入账 |
| sp_cancel_or_refund_order | STORE_MANAGER | 取消/实扣前全额退款、释放锁、积分作废、审计 |

所有岗位还须 C 授予 EXECUTE，数据库按 USER_NAME() 验证启用员工与 job_code；参数中的员工 ID 不能替代真实身份。

### sp_create_order

```sql
sp_create_order
@customer_id BIGINT,
    @fulfillment_method VARCHAR(20),
    @order_no VARCHAR(50),
    @items_json NVARCHAR(MAX),
    @ordered_at DATETIME2(0) = NULL
```

只有 @ordered_at 有默认 NULL，正常应用省略；非 test_* 显式传时间会被 52101 拒绝。items_json 是仅含整数 product_id、quantity 的非空对象数组；不能传角色、价格、父项或组件。order_no 必须由调用方在请求前生成并保存，重试不能临时换号掩盖结果未知。

| 当前 SQL 错误码 | 原始消息（源码） |
| --- | --- |
| 52100 | This operation requires the current active CASHIER employee. |
| 52101 | Only test_ principals may supply ordered_at. |
| 52102 | An active customer is required. |
| 52103 | Order number and PICKUP/DELIVERY fulfillment are required. |
| 52104 | items_json must be a JSON array. |
| 52105 | A nonempty array of product objects is required. |
| 52106 | Each item must contain only integer product_id and quantity. |
| 52107 | Product IDs and quantities must be positive and within range. |
| 52108 | Duplicate top-level products are not permitted. |
| 52109 | Every product must exist and be active with a valid type. |
| 52110 | Submit only the combo parent, never its child in the same payload. |
| 52111 | Single products need BOMs and combos need components. |
| 52112 | Combo children must be active SINGLE products with BOM and valid quantities. |
| 52113 | Pricing function must return exactly one price per product. |
| 52114 | Order amount is outside the supported monetary range. |

### sp_pay_order

```sql
sp_pay_order
@order_id BIGINT,
    @payment_method VARCHAR(20),
    @paid_amount DECIMAL(10,2),
    @third_party_txn_no VARCHAR(100)
```

@third_party_txn_no 可传 NULL，但没有默认值，必须显式绑定 DBNull。paid_amount 绑定 DECIMAL(10,2)，不用 double；payment_method 当前只验证非空白，不能宣称已有 CASH/扫码的数据库枚举白名单。重复支付通常先命中 52201，52204 是额外一致性守卫。

| 当前 SQL 错误码 | 原始消息（源码） |
| --- | --- |
| 52100 | This operation requires the current active CASHIER employee. |
| 52201 | Only a pending-payment order can be paid. |
| 52202 | Payment must equal the positive order total. |
| 52203 | Payment method is required. |
| 52204 | An order may have only one payment. |
| 52205 | Customer needs a current active member level with a positive multiplier. |
| 52206 | Calculated points exceed the supported integer range. |

### sp_start_production

```sql
sp_start_production
@order_id BIGINT
```

| 当前 SQL 错误码 | 原始消息（源码） |
| --- | --- |
| 52100 | This operation requires the current active CHEF employee. |
| 52301 | Only a PAID order can start production. |

### sp_finish_production

```sql
sp_finish_production
@order_id BIGINT
```

| 当前 SQL 错误码 | 原始消息（源码） |
| --- | --- |
| 52100 | This operation requires the current active PACKER employee. |
| 52401 | Only an IN_PRODUCTION order can finish production. |

### sp_pick_up_order

```sql
sp_pick_up_order
@order_id BIGINT
```

| 当前 SQL 错误码 | 原始消息（源码） |
| --- | --- |
| 52100 | This operation requires the current active PACKER employee. |
| 52501 | Only a READY_FOR_PICKUP pickup order can be collected. |
| 52502 | Exactly one PENDING points ledger is required for completion. |

### sp_pick_up_delivery

```sql
sp_pick_up_delivery
@order_id BIGINT,
    @rider_employee_id BIGINT
```

@rider_employee_id 必须等于当前身份上下文；不能选其他骑手代认领。

| 当前 SQL 错误码 | 原始消息（源码） |
| --- | --- |
| 52100 | This operation requires the current active RIDER employee. |
| 52601 | Rider parameter must identify the current active rider. |
| 52602 | Order must be READY_FOR_DELIVERY. |
| 52603 | Delivery must be unassigned and WAITING_PICKUP. |

### sp_confirm_delivery

```sql
sp_confirm_delivery
@order_id BIGINT
```

| 当前 SQL 错误码 | 原始消息（源码） |
| --- | --- |
| 52100 | This operation requires the current active RIDER employee. |
| 52701 | Order must be DELIVERING. |
| 52702 | Only the assigned active rider can complete this delivery. |
| 52502 | Exactly one PENDING points ledger is required for completion. |

### sp_cancel_or_refund_order

```sql
sp_cancel_or_refund_order
@order_id BIGINT,
    @reason VARCHAR(20),
    @operator_employee_id BIGINT
```

@operator_employee_id 来自真实店长上下文。未付 reason=CANCEL/PAYMENT_TIMEOUT；已付但未实扣仅 REFUND。没有部分退款或交付后退款接口。

| 当前 SQL 错误码 | 原始消息（源码） |
| --- | --- |
| 52100 | This operation requires the current active STORE_MANAGER employee. |
| 52801 | Operator parameter must identify the current active store manager. |
| 52802 | Only unpaid cancellation or full refund before inventory consumption is supported. |
| 52803 | Reason must match unpaid cancellation or full pre-consume REFUND. |
| 52804 | Unpaid cancellation cannot have a payment. |
| 52805 | Refund requires an untouched successful full payment; partial refunds are unsupported. |
| 52806 | Only PENDING points can be voided by a refund or cancellation. |

外域错误原样保留：例如 C 库存不足当前为 50000，A 积分入账可抛其自身编号；2601/2627 可能来自唯一键冲突、547 来自完整性约束。C 统一登记新错误码；应用不得把所有未知错误归成“库存不足”。

## 2. 新查询提案：名字沿用计划，结果列逐一列清

以下类型中 ? 表示 SQL NULL；未标 ? 为非 NULL 输出。它们是待 A/C 冻结的接口设计，当前仓库尚无这些过程。所有结果按稳定键排序，不 SELECT *，查询参数必须绑定；无结果返回空集合，权限/身份错误必须抛错，不冒充空集合。队列提案新增 @take INT=100（1..200）限定单次结果，最终分页协议由 A/C 审核。

| 查询 | 建议参数 | 岗位与过滤 | 返回结果 |
| --- | --- | --- | --- |
| sp_list_orders_for_payment | @take INT=100 | CASHIER；仅 PENDING_PAYMENT；ordered_at,order_id 升序 | RS1：order_id BIGINT、order_no VARCHAR(50)、total_amount DECIMAL(10,2)、ordered_at DATETIME2(0) |
| sp_get_order_for_payment | @order_id BIGINT | CASHIER；仅 PENDING_PAYMENT，不存在或状态已变明确失败 | RS1：同上加 fulfillment_method VARCHAR(20)；RS2：order_item_id BIGINT、product_id BIGINT、product_name NVARCHAR(50)、quantity INT、unit_price DECIMAL(10,2)、promotion_id BIGINT?，仅 SELLABLE，按 order_item_id |
| sp_get_order_operation_status | 计划最小 @order_id BIGINT；建议扩展 @order_id BIGINT=NULL、@order_no VARCHAR(50)=NULL，恰好一个非 NULL | CASHIER/STORE_MANAGER；全状态、精确单订单定位，不返回顾客资料 | RS1：order_id BIGINT、order_no VARCHAR(50)、order_status VARCHAR(20)、payment_status VARCHAR(20)?、paid_amount DECIMAL(10,2)?、refunded_amount DECIMAL(10,2)?、is_completed BIT、pickup_code VARCHAR(20)?；付款列 LEFT JOIN，不把无支付转成 0 |
| sp_list_orders_for_packing | @take INT=100 | PACKER；IN_PRODUCTION/READY_FOR_PICKUP，按 ordered_at,order_id | RS1：order_id BIGINT、order_no VARCHAR(50)、order_status VARCHAR(20)、fulfillment_method VARCHAR(20)、pickup_code VARCHAR(20)?；RS2：order_id BIGINT、order_item_id BIGINT、parent_order_item_id BIGINT?、item_role VARCHAR(20)、product_id BIGINT、product_name NVARCHAR(50)、quantity INT；只含 RS1 所选订单 |
| sp_list_my_deliveries | @take INT=100 | 当前启用 RIDER；仅 rider_employee_id=自身且 DELIVERING；picked_up_at,delivery_id 升序 | RS1：delivery_id BIGINT、order_id BIGINT、order_no VARCHAR(50)、delivery_status VARCHAR(20)、picked_up_at DATETIME2(0)? |
| sp_list_deliveries_available_for_pickup | @take INT=100 | 当前启用 RIDER；订单 READY_FOR_DELIVERY 且配送 WAITING_PICKUP、骑手 NULL；production_finished_at,order_id 升序 | RS1：delivery_id BIGINT、order_id BIGINT、order_no VARCHAR(50)、production_finished_at DATETIME2(0)?；无顾客和金额 |

配餐查询的 @take 限订单数而非明细数，RS2 必须返回所选订单全部明细，不能把套餐截断。制作项显示须区分套餐父项与组件，不把两者数量相加当原料需求。
两结果集查询必须在数据库内取得一致的订单键集合；状态可能在展示后变化，写过程再验证，不依赖页面缓存判断可操作性。

### 下单结果确认缺口与建议

现有 sp_create_order 不返回 order_id，而计划的状态查询只接收 order_id；新下单的客户端尤其在响应丢失时可能不知道该 ID。推荐将精确 order_no 查询纳入同名状态过程（上表），沿用已有唯一订单号，避免为了拿 ID 给收银开放完整详情视图或基表。这是一项待冻结的参数扩展，不是本轮新增实现。
读到无记录仍不证明旧请求永远不会提交：超时后先终止/释放旧调用并确认其事务结束，再按相同订单号重试；唯一约束是最终防重兜底，不能在结果未知时换订单号重下。

## 3. 已有读取对象与权限边界

v_kitchen_queue 给 CHEF；v_pickup_board 给 WAITER；店长按已有授权使用 v_order_detail 选择取消/退款订单。v_customer_point_ledger 不是收银支付页的数据源。视图精确授权以 08 为事实；不因视图存在就授予所有岗位。
商品、顾客检索/注册调用 A 的计划接口，B 不复制定价或创建会员规则；身份来自 C 上下文，B 不实现登录或自行 EXECUTE AS。

## 4. 冻结交接检查表

- A：核对 SQL 类型与语言参数、结果集数量/列顺序/NULL、Common 调用样例；状态查询按号定位提案是否接受。
- C：核对每对象岗位、员工停用拒绝、GRANT/白名单/种子、统一新错误编号；拒绝扩大到全表查询。
- B：按批准协议实现 11b 查询/必要兼容升级与 13b；支付恢复、无结果、状态竞争和越权都有详细用例。
- 任一改动须同步 B 文档、A 应用契约、C 授权材料后冻结；当前不改已有八个过程签名。
