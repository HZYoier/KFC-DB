# 成员 A（主数据·定价·会员）v0.1 问题与保留清单（a-issues）

> 属主：成员 A（计划 §7.1）。结构：每项含 ID、业务规则、当前对象、复现证据、保留 / 改动建议与影响对象。跨域条目另以 `OI-*` 编号登记到 `docs/stage2/open-issues.md`，本文件只引用不另维护状态。
>
> 事实基础：`sql/01_master_schema.sql`（A 域 10 表建表）与 `sql/04_master_constraints_crud.sql`（22 条命名 `CHECK`、18 个 CRUD 过程、2 个跨域接口对象）的源码；与第一阶段 A 域验收 `10a`（A1–A13，13 条）的对象口径一致。对应教学要求 R5-02、R5-03、R5-11。

## 1. 整理现有设计（A 域 10 表）

| 表 | 一行的业务含义 | 主码 | 候选标识 / 唯一键 | 外码 → 引用 |
| --- | --- | --- | --- | --- |
| `Category` | 一个商品分类 | `category_id` | 无声明式候选码 | — |
| `MemberLevel` | 一个会员等级及其积分倍率与升级门槛 | `member_level_id` | 无声明式候选码 | — |
| `Ingredient` | 一种可库存原料（含安全库存线） | `ingredient_id` | 无声明式候选码 | — |
| `Product` | 一个销售单元（单品或套餐） | `product_id` | 无声明式候选码 | — |
| `ProductCategory` | 一次商品与分类的归属（M:N 关联实体） | `(product_id, category_id)` 复合 | 复合主码即候选；另有过滤唯一 `UQ_ProductCategory_is_primary`（每商品至多一个主分类） | `product_id` → `Product`；`category_id` → `Category` |
| `Customer` | 一位顾客（散客 / WOW / 付费） | `customer_id` | `mobile` 唯一（`UQ_Customer_Mobile`） | `member_level_id`（可空）→ `MemberLevel` |
| `ProductBom` | 一条单品用料（每个销售单位消耗某原料的量） | `(product_id, ingredient_id)` 复合 | 复合主码即候选 | `product_id` → `Product`；`ingredient_id` → `Ingredient` |
| `ComboComponent` | 套餐中的一个子项组成 | `(combo_product_id, child_product_id)` 复合 | 复合主码即候选 | `combo_product_id` → `Product`；`child_product_id` → `Product`（同为 `Product`，自引用形状） |
| `Promotion` | 一次促销活动 | `promotion_id` | 无声明式候选码 | — |
| `PromotionProductRule` | 一条促销规则（某活动在某星期某时段对某商品的一口价） | `promotion_rule_id` | 无声明式候选码 | `promotion_id` → `Promotion`；`product_id` → `Product` |

补充（对应 R5-04 的复合主码讨论）：A 域共 3 个复合主码——`ProductCategory`、`ProductBom`、`ComboComponent`；其余 7 张为 `IDENTITY` 代理键。`Customer.mobile` 有全表唯一约束 `UQ_Customer_Mobile`；`ProductCategory` 另有一个过滤唯一索引 `UQ_ProductCategory_is_primary ON (product_id) WHERE is_primary = 1`（`01:66`），表达“每个商品至多一个主分类”，属**部分唯一**，不是候选码。

A 域外键 9 条，全部落在域内（见上表）。A 域不向外域发外码；外域指向 A 的**入边**共 7 条——B 的 `SalesOrderItem.product_id` → `Product`（`02:59`）、`SalesOrderItem.promotion_id` → `Promotion`（`02:61`）、`SalesOrder.customer_id` → `Customer`（`02:45`）、`PointLedger.customer_id` → `Customer`（`02:99`），C 的 `Inventory.ingredient_id`、`ReplenishmentSuggestion.ingredient_id`、`PurchaseOrderItem.ingredient_id` → `Ingredient`（`03:92`、`03:121`、`03:164`）。这些入边在 A 域子图中按跨域灰矩形处理。

## 2. 保留项（设计合理，写明理由）

**I-A01 定价只实现一处（保留）**
- 业务规则：某商品在某时刻的成交价，由商品基价与命中促销共同决定，且全局只能有一套判定。
- 当前对象：内联表值函数 `fn_get_effective_product_price`；`v_active_product_price` 与 B 的 `sp_create_order` 都调用它。
- 复现证据：过程定义；`10a` A7/A8（同一时刻、固定周四 `2026-10-01 12:00`，视图与函数返回同价同促销 ID）。
- 建议：保留——视图与下单路径不复制促销判断，杜绝两套规则漂移。影响：`07a` 视图、B 的下单过程。

**I-A02 商品基价可变、成交价快照冻结（保留）**
- 业务规则：`Product.base_price` 是“当前标准价”，可随改价变动；历史订单金额不受日后改价影响。
- 当前对象：`Product.base_price`（可变）；快照字段 `unit_price` / `promotion_id` 落在 B 的 `SalesOrderItem`。
- 复现证据：`10a` A4（改价确实落库）；B 的 `10b`「改商品价不影响历史订单快照」。
- 建议：保留——本域只维护“当前价”，历史价归 B 的快照列；不要在本域反算历史金额。影响：B 的订单明细、定价函数。

**I-A03 套餐只在 `ComboComponent` 留行、不配 `ProductBom`（保留）**
- 业务规则：单品的用料由 `ProductBom` 表达；套餐的用料由其子项展开，套餐自身不直接挂原料。
- 当前对象：`ProductBom`（仅单品）、`ComboComponent`（仅套餐子项）；BOM 视图两个分支分别处理。
- 复现证据：`09a` 种子（套餐只配 `ComboComponent`）；`10a` A12/A13（单品分支 4 行、套餐分支 9 行 3 子商品）。
- 建议：保留——套餐用料只经子项表达一次，避免套餐与子项双份用量。影响：`07a` 的 `v_product_bom_detail`、C 的锁库存展开。

**I-A04 过滤唯一索引表达“每商品至多一个主分类”（保留）**
- 业务规则：一个商品可属多个分类，但至多一个是展示用的主分类。
- 当前对象：`UQ_ProductCategory_is_primary`（过滤唯一索引，`01:66`）。
- 复现证据：索引定义；`v_active_product_price` 依赖 `is_primary = 1` 取展示分类。
- 建议：保留——声明式保证，不需要人工检查或过程自查。影响：视图取分类的分支。

**I-A05 `Customer.member_level_id` 是 A 域唯一可空列（保留）**
- 业务规则：顾客当前等级可空，语义是“原等级被停用而置空”，不是“从未建档”。
- 当前对象：`Customer.member_level_id`（可空外码）；其余受 `CHECK` 约束的列一律显式 `NOT NULL`。
- 复现证据：建表定义（`01:77`）；`10a` A2（新建顾客取默认等级）。
- 建议：保留——`CHECK` 在 `NULL` 上求值为 `UNKNOWN` 会放行，所以受约束列必须 `NOT NULL`；此处允许可空是业务需要，单独说明。影响：`sp_create_customer`、建档默认等级逻辑。

**I-A06 枚举取值的唯一权威是命名 `CHECK`（保留）**
- 业务规则：状态、类型等枚举列的合法取值，以命名 `CHECK` 为准。
- 当前对象：A 域 22 条 `CHECK`（数值 9、时间序 2、星期号 1、状态枚举 6、类型枚举 3、手机号 1）。
- 复现证据：`04` 的 `WITH CHECK ADD CONSTRAINT` 段（`04:112`–`04:142`）。
- 建议：保留——`01` 的列注释与 `docs/主数据数据字典.md` 都跟随 `CHECK`，不在三处各写一份自相矛盾的取值。影响：数据字典、B/C 对枚举值的引用。

**I-A07 手机号 `CHECK` 允许 `TEMP-` 游客临时号（保留）**
- 业务规则：真实会员手机号为 11 位纯数字；散客可用 `TEMP-` 前缀的临时号建档。
- 当前对象：`CK_Customer_mobile` 两分支（`04:139`）。
- 复现证据：约束定义；`10a` A1（重复手机号被拒 `51005`）。
- 建议：保留——`TEMP-` 分支让散客也能建档，避免订单缺 `customer_id`。影响：`sp_create_customer`、B 的顾客检索接口。

## 3. 观察与预计变更（非 v0.1 缺陷）

**I-A08 `Customer.current_points` 是否属于派生冗余（留待 2.2）**
- 观察：`Customer.current_points` 物化存放顾客累计积分，而积分流水在 B 的 `PointLedger`；两者的一致性由 A 的 `sp_apply_customer_points` 维护，没有约束直接保证。
- 建议：2.2 在 `docs/stage2/a-normalization.md` 按函数依赖判断——若 `current_points` 可由流水汇总推出，则与 `SalesOrder.total_amount` 是同类冗余议题，两者口径应一致（都保留并说明维护机制，或都改为派生）。影响：`sp_apply_customer_points`、B 的积分两段式、视图。

**I-A09 `MemberLevel` 与升级规则的函数依赖（留待 2.2）**
- 观察：`MemberLevel.threshold_points` 决定升级门槛，实际等级由顾客累计积分落在哪个门槛区间决定；本域只存等级与门槛的静态映射。
- 建议：2.2 分析 `member_level_id`、`threshold_points` 与积分的依赖关系，判断是否存在传递依赖，并说明“等级由积分规则派生”这一口径。影响：`sp_apply_customer_points`、会员等级维护过程。

**I-A10 三个复合主码表的 2NF / 3NF 判定（留待 2.2）**
- 观察：`ProductCategory`、`ProductBom`、`ComboComponent` 均为全码（所有列都在主码内或直接依赖全码），结构上无部分依赖。
- 建议：2.2 逐表写出候选码与函数依赖，明确它们是“全码、无部分依赖”，把“没有异常”也写成有依据的结论，而不是省略。影响：dictionaries、ER 子图。

**I-A11 “商品→类别→类别名”示例需按 FD 判断（留待 2.2）**
- 观察：教学原文用“商品编号→类别编号→类别名称”举例传递依赖，但本项目 `ProductCategory` 是 M:N 关联表，一个商品可属多分类，`product_id` 并不单值决定 `category_id`。
- 建议：2.2 明确本项目不构成该传递依赖（或另建独立示例关系演示），不为了凑示例而把 `ProductCategory` 强拆。影响：`a-normalization.md`、总图。

**I-A12 七张表无声明式候选码（留待 2.2 判定是否需要）**
- 观察：`Category`、`MemberLevel`、`Ingredient`、`Product`、`Promotion`、`PromotionProductRule` 仅有代理主码，名称列（如 `ingredient_name`、`product_name`）无唯一约束，同名行可并存。
- 建议：2.2 判断这些名称在业务上是否应唯一；若应唯一，是补唯一约束还是明确接受同名（如不同门店/规格），给出结论而非默认。影响：主数据字典、可能的迁移。

## 4. 跨域条目与接口索引

- 外域对 A 的入边外码 7 条，见 §1 末段；在 A 域子图按跨域灰矩形处理，实体名与键列与 B、C 的子图保持一致（`legend.md` §3.2）。
- A 对外提供的两个跨域接口对象：`fn_get_effective_product_price`（读，定价唯一入口）与 `sp_apply_customer_points`（写，只动 `Customer`、不碰 B 的 `PointLedger`）。它们是接口不是表，不进 ER 图，冻结口径见 `docs/stage1-cross-domain-interface-contract.md`。
- 与 C 的域属主更正相关：`OI-06`（`Ingredient` 属 A、`AuditLog` 属 C），已 closed 2026-10-14。
- 供应商范围：`OI-02`（closed）——供应商落在 C 域采购侧，与 A 域无关，此处仅备案。

## 5. 下一步（本文件之外）

- 与本文同步产出 `docs/er/a-master.drawio` / `.svg`：以上表行即子图的实体与键列来源，符号照 `docs/er/legend.md`。
- 本域联系条目提交给 B 汇总进 `docs/stage2/business-rule-mapping.md`（两端最小 / 最大基数 + 保证机制）。
- `docs/stage2/naming.md` 与 `design-validation.md` 待 C 合并总图后再定稿。
