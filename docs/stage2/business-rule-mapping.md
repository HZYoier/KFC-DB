# 业务规则与关系映射清单

> 主笔 B；2026-10-14。覆盖 R5-05/06/10/13/14/15。源码提取 25 表、35 条外键，A/C 业务条件参考其 issues；本文是可供合图的映射稿，不替全组签署冻结。
> 依据：[实施计划](../stage2-three-person-implementation-plan.md)、[A 素材](a-issues.md)、[B 素材](b-issues.md)、[C 素材](c-issues.md)、[图例](../er/legend.md)。

## 1. 不歧义的方向约定

下表统一为 P=被引用父表，C=持 FK 子表。“每 C 的 P 数”由 FK 可空性决定；“每 P 的 C 数”由子 FK 唯一性和父端参与规则决定。例：SalesOrder→SalesOrderItem 是每明细恰好一订单、每订单物理 0..N 明细，业务成功提交后至少一条 SELLABLE。
图中靠 P 的端点表示每 C 对应的 P 数，靠 C 的端点表示每 P 对应的 C 数；避免把“子 FK 可空”错误画成“父表只能零或一个子项”。C 图例文字若产生相反解读，提请 C 按此双向问句核对，不直接修改其文件。乌鸦脚图默认画 DDL 基数，额外业务最低数/条件以文字标注。

## 2. 全部声明式外键（35/35）

| ID | 外键名 | P ← C.FK | 每 C 的 P 数（DDL） | 每 P 的 C 数（DDL） | 业务条件 / 额外机制 |
| --- | --- | --- | --- | --- | --- |
| BR-01 | FK_ProductCategory_Product | Product ← ProductCategory.product_id | 1 | 0..N | 每商品主分类过滤唯一不限制非主分类；M:N 关联表 |
| BR-02 | FK_ProductCategory_Category | Category ← ProductCategory.category_id | 1 | 0..N | 同一分类可有多商品；无至少一商品的 DDL 保证 |
| BR-03 | FK_Customer_MemberLevel | MemberLevel ← Customer.member_level_id | 0..1 | 0..N | 顾客等级可空；业务支付另要求 ACTIVE 等级与正倍率 |
| BR-04 | FK_ProductBom_Product | Product ← ProductBom.product_id | 1 | 0..N | 合法售卖 SINGLE 需 BOM；不是所有 Product 均直接有 BOM |
| BR-05 | FK_ProductBom_Ingredient | Ingredient ← ProductBom.ingredient_id | 1 | 0..N | 原料可被多个商品使用 |
| BR-06 | FK_ComboComponent_ComboProduct | Product ← ComboComponent.combo_product_id | 1 | 0..N | COMBO/SINGLE 类型和正数量由约束/过程补充；有效下单套餐需子项 |
| BR-07 | FK_ComboComponent_ChildProduct | Product ← ComboComponent.child_product_id | 1 | 0..N | 子商品可用于多个套餐；不画成所有商品都是套餐子项 |
| BR-08 | FK_PromotionProductRule_Promotion | Promotion ← PromotionProductRule.promotion_id | 1 | 0..N | 非空 FK 保证引用存在；不保证父端至少有一个子项 |
| BR-09 | FK_PromotionProductRule_Product | Product ← PromotionProductRule.product_id | 1 | 0..N | 非空 FK 保证引用存在；不保证父端至少有一个子项 |
| BR-10 | FK_SalesOrder_Customer | Customer ← SalesOrder.customer_id | 1 | 0..N | 散客也引用顾客档案；会员等级可空≠订单顾客可空 |
| BR-11 | FK_SalesOrderItem_SalesOrder | SalesOrder ← SalesOrderItem.order_id | 1 | 0..N | 业务成功订单至少 1 SELLABLE；DDL 无父端最低数量保证 |
| BR-12 | FK_SalesOrderItem_Product | Product ← SalesOrderItem.product_id | 1 | 0..N | 同商品可关联多行；顶层重复输入被过程 52108 拒绝（I-B08） |
| BR-13 | FK_SalesOrderItem_Parent | SalesOrderItem ← SalesOrderItem.parent_order_item_id | 0..1 | 0..N | 仅 COMPONENT 业务必有父项且同单；SELLABLE 无父；同单/父角色由过程保证 |
| BR-14 | FK_SalesOrderItem_Promotion | Promotion ← SalesOrderItem.promotion_id | 0..1 | 0..N | 无促销/组件为 NULL，历史命中快照保留 |
| BR-15 | FK_Payment_SalesOrder | SalesOrder ← Payment.order_id | 1 | 0..1 | 未付可无；支付成功恰好一行；UQ_Payment_order_id |
| BR-16 | FK_Delivery_SalesOrder | SalesOrder ← Delivery.order_id | 1 | 0..1 | 仅外送完成制作后恰好一行；自取/外送此前可无；UQ_Delivery_order_id |
| BR-17 | FK_PointLedger_SalesOrder | SalesOrder ← PointLedger.order_id | 1 | 0..1 | 支付后恰好一行；终态生效、退款作废；UQ_PointLedger_order_id |
| BR-18 | FK_PointLedger_Customer | Customer ← PointLedger.customer_id | 1 | 0..N | FK 不保证与订单 customer_id 相同，sp_pay_order 保证 |
| BR-19 | FK_EmployeeBusinessRole_Employee | EmployeeAccount ← EmployeeBusinessRole.employee_id | 1 | 0..N | 复合主键防止同员工同角色重复 |
| BR-20 | FK_EmployeeBusinessRole_BusinessRole | BusinessRole ← EmployeeBusinessRole.business_role_id | 1 | 0..N | 一个角色可有多个员工 |
| BR-21 | FK_EmployeeBusinessRole_AssignedByEmployee | EmployeeAccount ← EmployeeBusinessRole.assigned_by_employee_id | 1 | 0..N | 第二条员工外键是授权操作者，不是被授权员工 |
| BR-22 | FK_RolePermission_BusinessRole | BusinessRole ← RolePermission.business_role_id | 1 | 0..N | 映射权限不等于实际 GRANT，C 同步核对 |
| BR-23 | FK_Inventory_Ingredient | Ingredient ← Inventory.ingredient_id | 1 | 0..1 | 共享主键使每原料至多一库存行，不保证所有原料已有库存 |
| BR-24 | FK_InventoryMovement_Inventory | Inventory ← InventoryMovement.ingredient_id | 1 | 0..N | 非空 FK 保证引用存在；不保证父端至少有一个子项 |
| BR-25 | FK_ReplenishmentSuggestion_Ingredient | Ingredient ← ReplenishmentSuggestion.ingredient_id | 1 | 0..N | 开放建议过滤唯一只限制特定状态，历史建议仍可多条 |
| BR-26 | FK_ReplenishmentSuggestion_CreatedByEmployee | EmployeeAccount ← ReplenishmentSuggestion.created_by_employee_id | 1 | 0..N | 非空 FK 保证引用存在；不保证父端至少有一个子项 |
| BR-27 | FK_ReplenishmentSuggestion_SubmittedByEmployee | EmployeeAccount ← ReplenishmentSuggestion.submitted_by_employee_id | 0..1 | 0..N | 该环节未发生可为 NULL；存在时 FK 校验员工 |
| BR-28 | FK_ReplenishmentSuggestion_ApprovedByEmployee | EmployeeAccount ← ReplenishmentSuggestion.approved_by_employee_id | 0..1 | 0..N | 该环节未发生可为 NULL；存在时 FK 校验员工 |
| BR-29 | FK_ReplenishmentSuggestion_RejectedByEmployee | EmployeeAccount ← ReplenishmentSuggestion.rejected_by_employee_id | 0..1 | 0..N | 该环节未发生可为 NULL；存在时 FK 校验员工 |
| BR-30 | FK_PurchaseOrder_ReplenishmentSuggestion | ReplenishmentSuggestion ← PurchaseOrder.replenishment_suggestion_id | 1 | 0..N | DDL 无 suggestion_id UNIQUE，故可多采购；过程单次审批只生成一单 |
| BR-31 | FK_PurchaseOrder_ApprovedByEmployee | EmployeeAccount ← PurchaseOrder.approved_by_employee_id | 0..1 | 0..N | 该环节未发生可为 NULL；存在时 FK 校验员工 |
| BR-32 | FK_PurchaseOrderItem_PurchaseOrder | PurchaseOrder ← PurchaseOrderItem.purchase_order_id | 1 | 0..N | 结构可多条，当前审批过程恰好一条；不误加父 INSERT 触发器 |
| BR-33 | FK_PurchaseOrderItem_Ingredient | Ingredient ← PurchaseOrderItem.ingredient_id | 1 | 0..N | 非空 FK 保证引用存在；不保证父端至少有一个子项 |
| BR-34 | FK_AuditLog_Employee | EmployeeAccount ← AuditLog.employee_id | 1 | 0..N | 审计主体必须存在；entity_id 多态引用不在本 FK 中 |
| BR-35 | FK_Delivery_RiderEmployee | EmployeeAccount ← Delivery.rider_employee_id | 0..1 | 0..N | 待取无骑手；认领/送达绑定当前骑手，C 创建此 FK |

DDL 保证机制：以上均有同名 FK；每 P 至多一 C 的四行另有子 FK 的 PK/UQ。其余父端 0..N 不从种子数据误推 1:1。组合主键中某一 FK 不能独自当唯一键。
涉及 B 的 BR-10—BR-18 与 BR-35 共 10 条，在 B 子图各出现一次；BR-13 是自引用。骑手 FK 的创建文件为 C 的 03，但关系子表归 B。其他 25 条供 A/C 合图查漏，不改 A/C 已交付子图。

## 3. 非 FK 业务规则与保证等级

| ID | 规则 | 表达与条件 | 当前保证 | 不能宣称的能力 |
| --- | --- | --- | --- | --- |
| RULE-B01 | 成功订单必须至少一售卖项 | SalesOrder→SalesOrderItem，提交后 SELLABLE >=1 | sp_create_order 原子事务、非空输入、岗位禁 DML | FK/普通 AFTER 主表触发器自动保证最低数 |
| RULE-B02 | 套餐快照 | 父 SELLABLE，子 COMPONENT，同单、子数=父数×配置量 | 过程展开；CHECK 保证角色/零价/父非自身的部分形状 | 自 FK 已保证同单、类型或无任意深层环 |
| RULE-B03 | 金额一致 | 主表=SELLABLE SUM，支付实收等于总额，全额退款保留原实付 | B 写过程与精度检查 | CHECK >=0 能证明跨表总额 |
| RULE-B04 | 积分事件闭环 | 支付 PENDING，取餐/送达 EFFECTIVE，实扣前退款 VOIDED | B 原子写入和 A 入账接口；order_id UQ | 一定等于所有历史 Customer 积分余额 |
| RULE-B05 | 骑手所有权 | 认领/确认只能是当前启用骑手 | USER_NAME→EmployeeAccount、角色授权、UPDLOCK/HOLDLOCK | 由客户端传 rider ID 即可信 |
| RULE-B06 | 原料锁与实扣 | 商品 BOM/套餐子项展开，锁→释放或实扣 | C 过程，同一 B 外层事务 | B 直接更新 Inventory |
| RULE-B07 | 库存流水多态单据引用 | reference_type=ORDER 时 reference_id 关联订单；采购则关联采购单 | C 过程、CHECK、视图解析，无该列 FK | 把此逻辑关联算进 35 条物理 FK |
| RULE-B08 | 订单审计多态引用 | AuditLog.entity_name/entity_id 指订单等对象 | C 审计过程，只有员工 FK | 图上将 entity_id 画成真实 SalesOrder FK |
| RULE-B09 | 同商品多行 | 表允许；过程禁止重复顶层商品和套餐父子同时输入 | 过程 52108/52110；教学 R5-13 需解释 | “现接口支持重复售卖行” |
| RULE-C01 | 采购单恰好一明细 | 当前审批生成策略，不是表的最大基数 | C 审批/收货过程和回归 | 复合主键使每采购单只能一明细 |

## 4. 合图与验收交接

C 合图时以外键名去重，不按实体对去重（EmployeeBusinessRole→EmployeeAccount 有两条不同语义边，ComboComponent→Product 亦有两条）。应核对总图 25 个实体、35 条 FK；业务逻辑虚线不得计入物理分母。
B 的五实体/53 列/10 FK 子图已生成；全组图仍需 A 子图、A 命名验证和 C 合并。I-B08 作为交接素材请 C 纳入唯一开放问题入口，B 不擅自改其状态。本文源码核验不等于活库结果；若部署目录与源码不同，先登记漂移再定稿。
