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

**2026-10-28：以下五条结论随 2.1 收口定稿**——B 的 `business-rule-mapping.md` 已于 10-24 冻结基数口径，C 的合并总图已于 10-27 交付并逐表核过实体键列，两条前置都齐了。每条结论末尾标注的「草案」保留为当时状态，不再逐条改写。

**I-A08 `Customer.current_points` 是否属于派生冗余（留待 2.2）**
- 观察：`Customer.current_points` 物化存放顾客累计积分，而积分流水在 B 的 `PointLedger`；两者的一致性由 A 的 `sp_apply_customer_points` 维护，没有约束直接保证。
- 建议：2.2 在 `docs/stage2/a-normalization.md` 按函数依赖判断——若 `current_points` 可由流水汇总推出，则与 `SalesOrder.total_amount` 是同类冗余议题，两者口径应一致（都保留并说明维护机制，或都改为派生）。影响：`sp_apply_customer_points`、B 的积分两段式、视图。
- **结论（2026-10-21，`a-normalization.md` §4.1；2026-10-27 订正：原写「完全可派生」不成立）**：**不能完全派生**——`09a:96`–`101` 给顾客 2、3 写了 500 / 1500 期初而无对应流水，口径是 `current_points = 期初 offset + SUM(EFFECTIVE point_delta)`；三条路径（PENDING 不计、EFFECTIVE 只加一次、VOIDED 只从 PENDING 转来）保证同事务原子。**保留物化**，与 `SalesOrder.total_amount` 同口径；2.2 在 `13a` 按三元组 `(current_points, SUM(EFFECTIVE), 差值=期初 offset)` 加断言，字典写明唯一维护入口，不删列改实时汇总。

**I-A09 `MemberLevel` 与升级规则的函数依赖（留待 2.2）**
- 观察：`MemberLevel.threshold_points` 决定升级门槛，实际等级由顾客累计积分落在哪个门槛区间决定；本域只存等级与门槛的静态映射。
- 建议：2.2 分析 `member_level_id`、`threshold_points` 与积分的依赖关系，判断是否存在传递依赖，并说明“等级由积分规则派生”这一口径。影响：`sp_apply_customer_points`、会员等级维护过程。
- **结论（2026-10-21，`a-normalization.md` §4.2，草案）**：**不存在传递依赖**——`current_points → member_level_id` 不成立，两条反例：等级停用把受影响顾客置空（`04:1326`–`1332`）、加档 / 调门槛不回溯（`04:86`–`95`）。`threshold_points` 的唯一性是等级解析正确的前提，已由两个过程 `THROW 51005` 强制但未声明 → **2.2 补 `UQ_MemberLevel_threshold_points`**；“不回溯”作为预期行为写进字典，防止 2.2 被当 bug 改掉。

**I-A10 三个复合主码表的 2NF / 3NF 判定（留待 2.2）**
- 观察：`ProductCategory`、`ProductBom`、`ComboComponent` 均为复合主码表，各有一个非主属性（`is_primary` / `usage_qty` / `quantity`）由整个复合码决定，结构上无部分依赖。**（2026-10-27 订正**：原写「均为全码」，与「全码＝候选码包含全部属性」的定义矛盾，`a-normalization.md` §4.3 已改。）
- 建议：2.2 逐表写出候选码与函数依赖，明确它们是「复合主码、无部分依赖」，把「没有异常」也写成有依据的结论，而不是省略。影响：dictionaries、ER 子图。
- **结论（2026-10-21，`a-normalization.md` §3.5–§3.8、§4.3，草案）**：三表均为复合主码表、各有非主属性，2NF/3NF 通过。两表（`ProductCategory`、`ProductBom`）的部分依赖方向各有种子反例；`ComboComponent.child_product_id ↛ quantity` 在种子里无重复、但按 R6-13 不能据此认定 FD，已写明“样例无重复不等于依赖成立”。**无需结构变更**。

**I-A11 “商品→类别→类别名”示例需按 FD 判断（留待 2.2）**
- 观察：教学原文用“商品编号→类别编号→类别名称”举例传递依赖，但本项目 `ProductCategory` 是 M:N 关联表，一个商品可属多分类，`product_id` 并不单值决定 `category_id`。
- 建议：2.2 明确本项目不构成该传递依赖（或另建独立示例关系演示），不为了凑示例而把 `ProductCategory` 强拆。影响：`a-normalization.md`、总图。
- **结论（2026-10-21，`a-normalization.md` §4.4，草案）**：反例在种子——商品 3 同属分类 2 与 1（`09a:71`），`product_id ↛ category_id`，该传递依赖在本项目**不成立**。演示用的独立示例关系（扁平表 + 无损分解）放 2.2 `refactoring-design.md`，**不进 v1.0 结构**。

**I-A12 六张表无声明式候选码（留待 2.2 判定是否需要）**
- 观察：`Category`、`MemberLevel`、`Ingredient`、`Product`、`Promotion`、`PromotionProductRule` 仅有代理主码，名称列（如 `ingredient_name`、`product_name`）无唯一约束，同名行可并存。**（2026-10-21 订正：原写“七张表”有误——`Customer` 有 `UQ_Customer_Mobile`，不在此列；正文一直只列 6 张，以正文为准。）**
- 建议：2.2 判断这些名称在业务上是否应唯一；若应唯一，是补唯一约束还是明确接受同名（如不同门店/规格），给出结论而非默认。影响：主数据字典、可能的迁移。
- **结论（2026-10-21，`a-normalization.md` §4.6，草案）**：补 5 个声明——`UQ_MemberLevel_threshold_points`（必做，§4.2）、`UQ_Category_category_name`、`UQ_Product_product_name`、`UQ_Ingredient_name_unit`、`UQ_MemberLevel_level_name`（建议）；**不补** `Promotion.promotion_name`（同名跨期合法）与规则窗口（同窗多档价是设计意图）。`09a` 种子在这些键上均无重复，迁移不会因存量数据失败。

## 4. 跨域条目与接口索引

- 外域对 A 的入边外码 7 条，见 §1 末段；在 A 域子图按跨域灰矩形处理，实体名与键列与 B、C 的子图保持一致（`legend.md` §3.2）。
- A 对外提供的两个跨域接口对象：`fn_get_effective_product_price`（读，定价唯一入口）与 `sp_apply_customer_points`（写，只动 `Customer`、不碰 B 的 `PointLedger`）。它们是接口不是表，不进 ER 图，冻结口径见 `docs/stage1/cross-domain-interface-contract.md`。
- 与 C 的域属主更正相关：`OI-06`（`Ingredient` 属 A、`AuditLog` 属 C），已 closed 2026-10-14。
- 供应商范围：`OI-02`（closed）——供应商落在 C 域采购侧，与 A 域无关，此处仅备案。

## 5. 下一步（本文件之外）

- 与本文同步产出 `docs/er/a-master.drawio` / `.svg`：以上表行即子图的实体与键列来源，符号照 `docs/er/legend.md`。
- 依赖与范式分析单独成文：**`docs/stage2/a-normalization.md`（2026-10-28 定稿，随 2.1 收口）**，本文 §3 的 I-A08–I-A12 结论见其 §4；结构对账证据 `result/stage2/a-normalization-check-2026-10-21.txt`（终轮 0 差异）。
- 本域联系条目提交给 B 汇总进 `docs/stage2/business-rule-mapping.md`（两端最小 / 最大基数 + 保证机制）：条目见 **§6**，共 16 条，与 `a-master.drawio` 的 r1–r16 一一对应。
- `docs/stage2/naming.md` 与 `design-validation.md` 待 C 合并总图后再定稿。

---

## 6. 本域联系条目（交 B 汇总 `business-rule-mapping.md`）

> 用途：计划 §4 要求「每条联系注明最小 / 最大基数、可空性、唯一性、业务条件和实际保证机制」，§7.1 指定本域素材由 A 提供、B 汇总成唯一口径、C 落到总图。本节 16 条与 `docs/er/a-master.drawio` 的 r1–r16 一一对应（16 实体 = A 域 10 表 + 跨域灰矩形 6 个）。
>
> **基数记法（与图一致，即 OI-07 要冻结的口径）：** 每端的数字回答「**对端每一条记录，对应本端多少条记录**」，图中某端的符号就是该端的基数，鸦爪恒在"多"端。下表写作 `源端 a..b / 目标端 c..d`，源端 = 图中 source（`startArrow` 一侧），目标端 = 图中 target（`endArrow` 一侧）。
>
> 「可空性 / 唯一性」两栏只写**结构事实**；业务上必需而结构不保证的部分一律落到「保证机制」栏，与计划 §4「物理外键只证明子项引用，不把它误画成父项必须至少有一个子项」一致。下表的保证机制按实物核实，**已订正图中标签不准确的三处**，见 §6.1。

| 联系 | 基数（源端 / 目标端） | 外码与关联列 | 可空性 / 唯一性 | 业务条件 | 保证机制（按实物核实） |
| --- | --- | --- | --- | --- | --- |
| r1 `Category` → `ProductCategory` | 1 / 0..N | `FK_ProductCategory_Category`（`ProductCategory.category_id`，`01:62`） | 非空（主码列）；复合主码含该列 → 同一「商品—分类」对至多一条 | 一个分类下可暂无商品；分类停用不改既有归属 | 声明式：外码非空 + 复合主码 `PK_ProductCategory`。注：`01:56` 列级未写 `NOT NULL`，主码列由引擎强制非空 |
| r2 `Product` → `ProductCategory` | 1 / 0..N | `FK_ProductCategory_Product`（`product_id`，`01:60`） | 非空（主码列）；另有过滤唯一索引限定主分类 | 每个商品建档即带一条**主**分类，可再属多个非主分类；主分类至多一个 | 主分类唯一：声明式（`UQ_ProductCategory_is_primary`，`01:66`）；商品端最小基数 1：**过程保证**——`sp_create_product` 对 `SINGLE` / `COMBO` 一视同仁地写入一条 `is_primary=1`（`04:413`；`@category_id` 为空即 `THROW 51000`，`04:377`）。外码方向无法表达父端最小基数，故图中端点只画到 0..N。**标签已按此订正**，见 §6.1 |
| r3 `Product` → `ComboComponent`（父项） | 1 / 0..N | `FK_ComboComponent_ComboProduct`（`combo_product_id`，`01:104`） | 非空（主码列）；复合主码 | 只有套餐配置组成行，单品无 | 声明式（外码非空 + 复合主码）。父端最小基数未主张，本项不声称任何参与约束 |
| r4 `Product` → `ComboComponent`（子项） | 1 / 0..N | `FK_ComboComponent_ChildProduct`（`child_product_id`，`01:106`） | 非空（主码列）；复合主码 | 同一商品可既是某套餐父项、又是别的套餐子项；同一对实体间的第二条外码（图中虚线） | 声明式（外码非空 + 复合主码） |
| r5 `Product` → `ProductBom` | 1 / 0..N | `FK_ProductBom_Product`（`product_id`，`01:91`） | 非空（主码列）；复合主码 | 只有单品配用料；套餐用料经 `ComboComponent` 展开，套餐自身不配 BOM 行（I-A03） | 声明式（外码非空 + 复合主码）。「套餐不配 BOM 行」无结构限制，属业务约定（体现 I-A03） |
| r6 `Ingredient` → `ProductBom` | 1 / 0..N | `FK_ProductBom_Ingredient`（`ingredient_id`，`01:93`） | 非空（主码列）；复合主码 | 一种原料可被多个商品的用料引用 | 声明式（外码非空 + 复合主码） |
| r7 `MemberLevel` → `Customer` | 0..1 / 0..N | `FK_Customer_MemberLevel`（`Customer.member_level_id`，`01:80`） | **可空**（A 域唯一可空列，I-A05）；非唯一 | 新顾客建档取默认档（`threshold_points <= 0` 的启用档）；等级停用时把受影响顾客置空 | 结构上 0..1（可空外码）。「启用顾客必有等级」= **过程保证**：`sp_create_customer`（`04:1398`–`04:1410`，找不到可用默认档即 `THROW 51001`）；「停用即置空」= 过程保证 `sp_update_member_level_status`（`04:1325`–`04:1332`） |
| r8 `Promotion` → `PromotionProductRule` | 1 / 0..N（业务口径最小 1） | `FK_PromotionProductRule_Promotion`（`promotion_id`，`01:132`） | 非空；非唯一 | 活动必须至少有一条规则才有意义 | **结构只到 0..N**——外码非空只证明规则必属某个活动，不证明活动必有规则。业务要求的最小 1 **当前无实现机制**：`sp_create_promotion` 只插活动行（`04:844`），`sp_update_promotion_status` 只翻状态、不校验规则数（`04:917`），全库无触发器。端点已按结构口径改回 `ERzeroToMany`，业务要求留在标签；「上线前须 ≥1 条规则」列为 A 域 2.2 的改动项，见 §6.1 |
| r9 `Product` → `PromotionProductRule` | 1 / 0..N | `FK_PromotionProductRule_Product`（`product_id`，`01:134`） | 非空；非唯一 | 一条规则只对一种商品定价；同商品可在多个活动 / 时段各有一条 | 声明式（外码非空） |
| r10 `Customer` → `SalesOrder`（B 域） | 1 / 0..N | `FK_SalesOrder_Customer`（`SalesOrder.customer_id`，`02:45`） | 非空（B 域列）；非唯一 | 散客也先建档（`TEMP-` 临时号，I-A07），订单不会缺顾客 | 声明式（B 域外码非空）；A 侧只提供被引用键，不维护该列 |
| r11 `Customer` → `PointLedger`（B 域） | 1 / 0..N | `FK_PointLedger_Customer`（`PointLedger.customer_id`，`02:99`） | 非空（B 域列）；非唯一 | 积分流水在 B 域，A 只维护 `Customer.current_points` 物化值（I-A08） | 声明式（B 域外码非空）；两表一致性由跨域接口 `sp_apply_customer_points` 维护，无约束保证 |
| r12 `Product` → `SalesOrderItem`（B 域） | 1 / 0..N | `FK_SalesOrderItem_Product`（`SalesOrderItem.product_id`，`02:59`） | 非空（B 域列）；非唯一 | 每条订单明细引用一种商品；商品与促销都按下单时点写入明细快照（I-A02、I-A03） | 声明式（B 域外码非空）；A 侧只提供被引用的 `Product` 键。**2026-10-16 订正**：原图源端误画为 `Customer`（`SalesOrderItem` 并无 `customer_id` 列），已改回 `Product`，否则 A 域 7 条入向跨域外码只覆盖 6 条，见 §6.1 |
| r13 `Ingredient` → `Inventory`（C 域） | 1 / 0..1 | `FK_Inventory_Ingredient`（`Inventory.ingredient_id`，`03:91`） | 非空，且就是 C 域主码 `PK_Inventory`（`03:87`） | 原料可暂时没有库存行；有库存行则与原料共享同一标识（PKFK，1:1 形状） | 声明式：C 域外码非空 + 共享主码；无反向外码，故目标端最小 0（计划 §4 要求分清单向引用） |
| r14 `Ingredient` → `ReplenishmentSuggestion`（C 域） | 1 / 0..N | `FK_ReplenishmentSuggestion_Ingredient`（`03:121`） | 非空（C 域列）；非唯一 | 一种原料可有历史补货建议 | 声明式（C 域外码非空） |
| r15 `Ingredient` → `PurchaseOrderItem`（C 域） | 1 / 0..N | `FK_PurchaseOrderItem_Ingredient`（`03:164`） | 非空（C 域列）；复合主码之一 | 采购明细引用原料；同原料可在多张采购单 | 声明式（C 域外码非空） |
| r16 `Promotion` → `SalesOrderItem`（B 域） | **0..1** / 0..N | `FK_SalesOrderItem_Promotion`（`SalesOrderItem.promotion_id`，`02:61`） | **可空**（B 域列）；非唯一 | 命中促销时把促销 ID 写进明细快照；未命中为空 | 结构上 0..1（可空外码）；快照写入由 B 的 `sp_create_order` 负责；改促销不影响历史明细（I-A02）。标为「0:1」指的是明细侧的最小 / 最大，与端点符号一致 |

### 6.1 图中标签与实物的三处不一致（已于 2026-10-16 订正）

按实物逐条核对后发现三处对不上，均已改进 `docs/er/a-master.drawio`（`.svg` 待重导）。三处都不改变 v0.1 的任何表结构。

1. **r12 悬空，同时漏掉一条在册入向跨域外码。** 原图 r12 画成 `Customer → SalesOrderItem`、标签「订单明细引用顾客」，但 `SalesOrderItem` **没有 `customer_id` 列**（`02:47`–`02:62` 只有 `order_id` / `product_id` / `parent_order_item_id` / `promotion_id` 四条外码）。这条既无实物支撑，又把真正在册的入向外码 `FK_SalesOrderItem_Product`（`02:59`）顶掉了——A 域 7 条入向跨域外码实际只覆盖 6 条，而计划 §4 的完成标准是「总图合并后 25 张表与 35 条外键**全部在图上有落点**」，放任则 C 合图时会既缺一条又多一条。
   **订正：** 源端由 `E_CUST` 改为 `E_PROD`，标签改为「1:N 订单明细引用商品（B 域）」；「订单明细引用顾客」不另画——该路径由 `Customer → SalesOrder → SalesOrderItem` 传递表达，ER 图不重复画同一条业务事实。走线改为从 `Product` 右下角出、经 x=1740 竖段落到 y=436 的水平段进入 `SalesOrderItem`，使标签落在走廊里（见附注）。
2. **r8 的「过程保证」不成立。** 端点原画成 `ERoneToMany`（最小基数 1）、标签写「业务必需 / 过程保证」，但 `sp_create_promotion` 只插活动行（`04:844`）、`sp_update_promotion_status` 只翻状态、不校验规则数（`04:917`），全库无触发器——**没有任何一步会拒绝"零规则的活动"**。
   **订正：** 端点改回结构口径 `ERzeroToMany`，标签改为「业务必需 / 无实现机制（2.2 待补校验）」，业务要求的最小 1 只作口径陈述、不冒充实现在册——与 r2 的处理方式统一（见下条）。**遗留一项 2.2 改动**：在 `sp_update_promotion_status`（或规则维护过程）里补上「上线前须 ≥1 条规则」的校验，最小基数 1 才算真正落实。空活动确实该被挡，但因 2.1 只动 `docs/`，本项登记为 A 域 2.2 的改动项，不放进本子阶段。
3. **r2 的标签把机制说小了。** 原写「单品必须 ≥1、套餐可为 0 — 业务必需 / 无结构保证」。实物是 `sp_create_product` 对 `SINGLE` 与 `COMBO` 一视同仁、建档必写一条 `is_primary=1`（`04:413`；`@category_id` 为 `NULL` 直接 `THROW 51000`，`04:377`），所以「套餐可为 0」与实现不符，「无结构保证」也只说对了一半。
   **订正：** 标签改为「1:N 建档即写一条主分类 — 过程保证，声明式不可表达」，端点维持 `ERzeroToMany`（外码方向无法表达父端最小基数）。

**三处订正后的统一口径**（建议 B 汇总基数时直接采用）：**端点符号一律只表达 DDL 能保证的结构基数，业务上必需而结构不保证的参与约束一律写进标签文字。** 本域按此口径自查：r2（商品端 0..N 结构 + 建档过程保证）、r8（活动端 0..N 结构 + 业务要求无机制）、r7 与 r13（可空外码的 0..1）、r16（可空外码的 0..1）四处均已一致。

**附注（改图时的版面约束与本次处理）：** 标签带白底，列走廊宽度必须 ≥ 该标签估宽，否则会啃掉相邻实体的属性行。r12 改挂 `Product` 后，其标签「1:N 订单明细引用商品（B 域）」估宽约 170px，而 col3↔col4 走廊原只有 120px，故把该走廊加宽到 360px（col4 三表 x 1760→2000、r11 与 r16 的 4 个拐点同步平移、`pageWidth` 2200→2440）；三条走廊现为 400 / 360 / 360。改动后用与导出实测相符的几何模型复查：**16/16 标签不压实体、不互相压，0 条折线穿实体框**。

> 三处均属 A 自己的图与标签层面，不改变 v0.1 的任何表结构；基数口径以 §6 表格为准，图已与表格对齐。
