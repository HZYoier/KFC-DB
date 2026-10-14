# 成员 B：v0.1 问题与保留清单

> 属主：B；日期：2026-10-14；源码基线：`83176e6`，第一阶段 SQL 固定基线见[实施计划](../stage2-three-person-implementation-plan.md) §0。
> 本文以建表、约束、过程、视图源码为证据，不冒充本轮活库测试。覆盖 R5-02/03/04/08/11/13/14/15。跨域状态只由 C 在 [open-issues](open-issues.md) 维护；本文的建议不是全组冻结决议。

## 1. 五张表与实体标识

| 表 | 一行代表什么 | 主码 | 其他标识 | 外码 |
| --- | --- | --- | --- | --- |
| SalesOrder | 一次下单及履约生命周期 | order_id | order_no：非空唯一候选码；pickup_code：仅非 NULL 子集唯一，不是全关系候选码 | customer_id → Customer |
| SalesOrderItem | 一个售卖项或一个套餐组成快照项 | order_item_id | 无其他已声明候选码；(order_id, product_id) 不唯一 | order_id → SalesOrder；product_id → Product；parent_order_item_id → 本表；promotion_id → Promotion |
| Payment | 某订单唯一一次业务支付及可能的全额退款 | payment_id | order_id：非空唯一候选码；第三方流水号不唯一且可空 | order_id → SalesOrder |
| Delivery | 外送订单的一条认领/送达记录 | delivery_id | order_id：非空唯一候选码 | order_id → SalesOrder；rider_employee_id → EmployeeAccount，可空 |
| PointLedger | 某订单唯一一笔预计算、入账或作废积分 | point_ledger_id | order_id：非空唯一候选码 | order_id → SalesOrder；customer_id → Customer |

属性全集及类型见[订单履约数据字典](../订单履约数据字典.md)，[B 子图](../er/b-order.svg)逐列落图。五表共 53 列，10 条外键（含 C 在 `03` 增补的骑手外键）。
证据：`02_order_schema.sql` 五张 CREATE TABLE；`05_order_constraints_crud.sql` 唯一约束、过滤索引与 CHECK；`03_inventory_security_schema.sql` 的 `FK_Delivery_RiderEmployee`。
顾客实体与会员身份不同：散客也有 Customer 档案，订单 customer_id 非空；可空的是 Customer.member_level_id，不能画成“订单可无顾客”。

## 2. 保留项

每项均为“规则 → 证据 → 影响与建议”，不是待修缺陷。

### I-B01 订单与至少一条售卖明细：保留原子过程保证

业务要求成功订单至少一条 SELLABLE；DDL 外键只保证明细引用已有订单，主表自身不能证明已有明细。
证据：`sp_create_order` 拒绝空数组（52105），同事务插主表、父明细、子明细、汇总总额及锁库；失败回滚；岗位无基表 DML。
建议：保留，不在主表 INSERT 后加立即检查子项的触发器。影响：ER 业务基数 1..N 与物理 0..N 分开表示；增加中途失败/直接 DML 反例至未来 13b。

### I-B02 历史定价快照：保留

商品现在的基价不能决定历史成交价。证据：下单调用 A 的 `fn_get_effective_product_price`，存 unit_price / promotion_id；B 不复制促销算法。
建议：保留快照；quantity × unit_price 只按 SELLABLE 计收入，COMPONENT 固定零价、促销 NULL。影响：订单详情、支付、销量、迁移基线。

### I-B03 套餐父子明细：保留，但区分配置与快照

Product/ComboComponent 是 A 的当前配置；SalesOrderItem 的父子行是 B 的下单快照。子项 quantity = 父数量 × 配置数量，不允许调用方提交组件。
证据：`sp_create_order` 展开组件；CHECK 限 COMPONENT 有非自身 parent、零价、无促销；C 读取单品售卖项和组件取 BOM。
建议：保留自引用，不把 SalesOrderItem 当作 ComboComponent 的重复副本。当前配置变化不回写历史行。影响：C 锁库/实扣及 B 厨房视图。

### I-B04 支付与积分每单至多一条：保留

证据：UQ_Payment_order_id / UQ_PointLedger_order_id；`sp_pay_order` 在同事务写支付、订单 PAID、积分 PENDING。
业务是“一次完整业务支付”，不是第三方多次尝试日志；部分退款、失败尝试流水不在范围。
建议：保留；未支付订单可以没有这两行，不能画为所有订单恰好一条。

### I-B05 配送记录的创建时点：保留

外送完成制作即插 WAITING_PICKUP，认领才绑定骑手，送达变 DELIVERED。
证据：`sp_finish_production`、`sp_pick_up_delivery`、`sp_confirm_delivery`；Delivery.order_id 唯一，骑手外键可空。
建议：保留。自取永无配送；外送在完成制作前也可没有配送。WAITING_PICKUP 在现实现中可达，不是死状态。

### I-B06 积分两段式与域边界：保留

支付只预计算；自取/送达终态才将 PENDING → EFFECTIVE 并调用 A 入账；实扣前退款 PENDING → VOIDED。
证据：`sp_pay_order`、`sp_pick_up_order`、`sp_confirm_delivery`、`sp_cancel_or_refund_order`。
建议：B 不更新 Customer 积分/等级，A 不写 PointLedger；保留实付/倍率快照。影响：A I-A08 与跨域回滚验收。

## 3. 需要论证或决议的项

### I-B07 total_amount 派生冗余：B 建议保留，2.2 冻结前确认

规则：total_amount = SUM(SELLABLE.quantity × unit_price)，金额两位小数。
证据：`sp_create_order` 使用高精度中间量并检查 99999999.99 上限；支付、退款和 `v_order_detail` 读取该列。
风险：DBA 直接改明细可能破坏一致性，CHECK >=0 不能检查跨表 SUM。
建议：保留以兼容支付/退款读取和既有接口，明确受控反规范化，并在迁移前后逐单校验。详见[b-normalization](b-normalization.md)；不声称跨表聚合自动违反本表 3NF。

### I-B08 同商品多行：表、过程、教学提示存在语义差异

规则现状：DDL 无 (order_id, product_id) 唯一约束；`sp_create_order` 却以 52108 拒绝重复顶层 product_id，52110 拒绝同一请求同时提交套餐及其子商品。
教学 R5-13 提示不要默认同商品只能一行。套餐生成还可能使相同子商品出现在不同父项下。
建议：图按多行能力建模；正式提交 2.1 前请 C 对照 R5-13 确认是保留“顶层合并输入”约定，还是 2.2 支持重复售卖行。B 提供两方案影响：保留需说明该提示如何满足；放开需调整 @parents 关联、输入规则、库存与验收，不仅删除一条 IF。
当前不改 SQL，不将“表允许”写成“现有下单接口允许”。影响：B 创建订单、A/C 测试输入、未来界面行模型。

### I-B09 父子同单同类型：过程保证强于 DDL

自 FK 只能保证父行存在；CHECK 不能证明父行为同订单的 SELLABLE，也不能证明父商品 COMBO、子商品 SINGLE。
证据：`FK_SalesOrderItem_Parent`、`CK_SalesOrderItem_item_role` 与 `sp_create_order` 组件构造。
建议：正常入口保留；13b 加同单/角色/数量不变量核对。是否新增复合外键或拆子类型留作 2.2 方案，不直接改 C 消费的明细接口。

### I-B10 PointLedger.point_delta 是可计算值：明确反规范化

规则：point_delta = FLOOR(paid_amount_snapshot × point_multiplier_snapshot)，输入二元组不是候选码。
证据：`sp_pay_order` 公式与 INT 上限检查；声明式 CHECK 只约束 >=0。
建议：保留作为待入账/已入账的事件金额，明确该公式下非键决定非主属性，不把表直接称为严格 3NF；加公式一致性回归。若删除该列须升级 A 调用实参、两种完成过程、视图及 C 汇总，未经冻结不实施。

### I-B11 PointLedger 顾客与订单顾客一致：跨表不变量

两个独立 FK 只能证明顾客和订单存在，不能保证 ledger.customer_id = SalesOrder.customer_id。
证据：`sp_pay_order` 从锁定订单取 customer_id 写流水，DDL 无复合引用。
建议：保留过程写入边界；基线/13b 逐笔检查，不用“两个 FK”冒充同顾客约束。若新增约束，B 先列依赖和存量异常处置。

## 4. 提交给 A/C 的交接素材（非外部消息）

| 素材 | 接收人 | 必须明确的事项 | 本轮边界 |
| --- | --- | --- | --- |
| I-B08 | C 需求核对、A/C 调用方 | R5-13 与重复顶层商品规则的解释/迁移范围 | 待共同确认，不改全组问题表状态 |
| I-B07 / I-B10 | A 范式素材、C 迁移汇总 | 总额、积分事件值分别论证，不强制同时删除 | B 推荐保留并补回归 |
| B 图中 10 条外键 | C 合图、A 命名 | 骑手键虽在 03 创建，子表仍属 B | 使用同名实体，不修改 C 图 |
| 积分累计来源 | A I-A08 | 不默认 current_points = 本库 EFFECTIVE 总和；需核对期初/人工调整来源 | 仅提供流水口径 |

## 5. 本轮核验边界

已完成源码核对和文件静态检查；本轮不连接或改动业务数据库、不运行写入测试。未来迁移/应用测试用例见[事务规范](transaction-boundaries.md)和[重构方案](refactoring-design.md)，不能把它们记为本轮 PASS。
