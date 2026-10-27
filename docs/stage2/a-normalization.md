# A 域函数依赖与规范化分析（a-normalization）

> 属主：成员 A（计划 §7.1）。**状态：草案（2026-10-21），尚未随 2.1 收口**——待 B 的 `business-rule-mapping.md` 与 C 的合并总图定稿后，再回填 §3、§4 的交叉引用并补 §6 的人工复核记录。
>
> 对应教学要求 **R6-08**（逐表：候选码、关键函数依赖、三类异常、范式判断及依据；满足要求者说明保留理由），并承接 R6-03（异常各附数据例子，无异常写明依据）、R6-04（逐表 1NF/2NF/3NF 与拆分 / 合并 / 保留方案及新关系属性与码）、R6-05（无损连接与依赖保持论证，本域示例见 §4.4）、R6-15（保留须有分析证据，不为演示异常破坏原结构）——编号以 `docs/stage2/source-requirements.md` 为唯一依据（教学原文已删）。
>
> 判定口径（计划 §5）：2NF 检查**所有候选码**（不只看主键）；3NF 分析**非平凡 FD 的决定因素**（不只看主码）；样例没有重复值不代表依赖不成立；代理主键（`IDENTITY`）不消除任何依赖；表不是越多越好，结构合理就保留并给出证据。
>
> 事实基础：v0.1 冻结基线（提交 `b557d49` 的 `sql/`，计划 §0）中的 `sql/01_master_schema.sql`（A 域 10 表建表，`01:17`–`01:136`）与 `sql/04_master_constraints_crud.sql`（22 条命名 `CHECK`、18 个 CRUD 过程、定价函数与积分入账过程）。数据例子取自 `sql/09a_master_seed_data.sql` 的种子形状。
>
> 术语：**候选码**＝候选标识（主码以外的一切极小唯一标识）；FD 记号 `X → Y`；**非主属性**＝不属于任何候选码的属性；**全码**＝候选码包含全部属性。
>
> 关联文件：`docs/stage2/a-issues.md`（保留项 I-A01…I-A07；观察项 I-A08…I-A12 的结论已由本文 §4 收口）；`docs/主数据数据字典.md`（逐字段中文口径）；`docs/er/a-master.drawio` / `.svg`（16 实体 16 联系，A 域 10 表 + 跨域灰矩形 6 个）。本文的分析结果是 2.2 重构方案（B 主笔 `refactoring-design.md`）的 A 域素材，结构变更由 `11a` 在 2.2 执行。

## 1. 分析对象与结论摘要

A 域共 **10 表、47 列、10 个主键**（含 3 个复合主键：`ProductCategory`、`ProductBom`、`ComboComponent`；其余 7 张为 `IDENTITY(1,1)` 代理键）、**1 个 `UNIQUE` 约束**（`UQ_Customer_Mobile`）、**1 个过滤唯一索引**（`UQ_ProductCategory_is_primary`，不是候选码，见 §4.5）、**9 条表内外键**（全部落在 A 域内）、**1 个可空列**（`Customer.member_level_id`，I-A05）、**22 条命名 `CHECK`**（`04:112`–`04:142`，数值 9 / 时间序 2 / 星期号 1 / 状态枚举 6 / 类型枚举 3 / 手机号 1）。

| 表 | 一行代表什么 | 候选码 | 范式判定 | 结论 |
| --- | --- | --- | --- | --- |
| `Category` | 一个商品分类 | `category_id`；`category_name`（业务应唯一，**未声明**） | 1NF/2NF/3NF 通过（决定因素均为单属性候选码，达 BCNF） | 保留结构 + **补声明**（I-A12，§4.6） |
| `MemberLevel` | 一个会员等级及其积分倍率与升级门槛 | `member_level_id`；`threshold_points`（业务唯一、**过程强制**、未声明） | 通过（达 BCNF；按业务 FD 判定亦然） | 保留结构 + **补声明**（I-A09、I-A12，§4.2 / §4.6） |
| `Ingredient` | 一种可库存原料（含安全库存线） | `ingredient_id`；`(ingredient_name, unit_name)`（业务应唯一，**未声明**） | 通过（BCNF） | 保留结构 + **补声明**（I-A12） |
| `Product` | 一个销售单元（单品或套餐） | `product_id`；`product_name`（业务应唯一，**未声明**） | 通过（BCNF） | 保留结构 + **补声明**（I-A12） |
| `ProductCategory` | 一次「商品 × 分类」的归属（M:N 关联实体） | `(product_id, category_id)`（复合 PK，非主属性 1 个） | 通过（BCNF，无部分依赖，§4.3） | 保留 |
| `Customer` | 一位顾客（散客 / WOW / 付费） | `customer_id`；`mobile`（`UQ_Customer_Mobile`） | 通过；`current_points` 为**跨表物化派生值**（§4.1），`member_level_id` 不是传递依赖的结果（§4.2） | 保留（I-A08 结论：保留物化） |
| `ProductBom` | 一条单品用料（每个销售单位消耗某原料的量） | `(product_id, ingredient_id)`（复合 PK，非主属性 1 个） | 通过（BCNF，无部分依赖，§4.3） | 保留 |
| `ComboComponent` | 套餐中的一个子项组成 | `(combo_product_id, child_product_id)`（复合 PK，非主属性 1 个） | 通过（BCNF，无部分依赖，§4.3） | 保留 |
| `Promotion` | 一次促销活动 | `promotion_id`（**无业务候选码**，同名跨期合法） | 通过（BCNF；决定因素唯一） | 保留（§4.6） |
| `PromotionProductRule` | 一条促销规则（某活动在某星期某时段对某商品的一口价） | `promotion_rule_id`（**无自然键**：窗口可重复，§3.10） | 通过（BCNF） | 保留；**不补**窗口唯一约束（§3.10 / §4.6） |

**合并结论：本域没有应当合并的表对。** 10 张表各承载互异的事实：4 张字典（分类 / 等级 / 原料 / 商品）、3 张全码关联（商品—分类 / 商品—原料 / 套餐—子项）、1 张实体（顾客）、2 张促销（活动头 / 规则行）。三张关联表虽都只有 2–3 列，但分别回答「商品属于哪些分类」「单品消耗哪些原料」「套餐由哪些子项组成」，合并会同时丢掉三者各自的复合主码语义，并让「同一商品既是某套餐子项、又有自己的 BOM」无法表达（用例：商品 1 既是 `ProductBom` 的单品（`09a:78`），又经 `ComboComponent` 进入套餐 5（`09a:89`））。

**拆分结论：本域没有应当拆分的表。** 唯一形似冗余的是 `Customer.current_points`（可由 B 域 `PointLedger` 的 `EFFECTIVE` 流水加总再加期初余额推出，§4.1）与 `PromotionProductRule` 的同窗多行（§3.10），两者都不构成表内 FD 违规，按 §4 给出的口径保留，不拆表。

## 2. 属性与键清单（对应 R6-02 的分析对象盘点）

表格式：`表 | 属性 | 类型 | 可空 | 键与约束（结构，源自 sql/01）`。`·` 分隔多项；`—` 表示无结构键；`IDENTITY(1,1)` 为自增。`CHECK` 全部在 `04` 批次 1（`04:112`–`04:142`），不逐行列在本表，逐表分析见 §3。

| 表 | 属性 | 类型 | 可空 | 键与约束 |
| --- | --- | --- | --- | --- |
| `Category` | `category_id` | `BIGINT` | 否 | `PK_Category`·`IDENTITY(1,1)` |
| `Category` | `category_name` | `NVARCHAR(50)` | 否 | — |
| `Category` | `status` | `VARCHAR(20)` | 否 | — |
| `MemberLevel` | `member_level_id` | `BIGINT` | 否 | `PK_MemberLevel`·`IDENTITY(1,1)` |
| `MemberLevel` | `level_name` | `NVARCHAR(50)` | 否 | — |
| `MemberLevel` | `point_multiplier` | `DECIMAL(5,2)` | 否 | — |
| `MemberLevel` | `threshold_points` | `INT` | 否 | —（业务唯一由过程强制，§4.2） |
| `MemberLevel` | `status` | `VARCHAR(20)` | 否 | — |
| `Ingredient` | `ingredient_id` | `BIGINT` | 否 | `PK_Ingredient`·`IDENTITY(1,1)` |
| `Ingredient` | `ingredient_name` | `NVARCHAR(50)` | 否 | — |
| `Ingredient` | `unit_name` | `NVARCHAR(50)` | 否 | — |
| `Ingredient` | `safety_stock_qty` | `DECIMAL(12,3)` | 否 | — |
| `Ingredient` | `status` | `VARCHAR(20)` | 否 | — |
| `Product` | `product_id` | `BIGINT` | 否 | `PK_Product`·`IDENTITY(1,1)` |
| `Product` | `product_name` | `NVARCHAR(50)` | 否 | — |
| `Product` | `base_price` | `DECIMAL(10,2)` | 否 | — |
| `Product` | `product_type` | `VARCHAR(20)` | 否 | — |
| `Product` | `status` | `VARCHAR(20)` | 否 | — |
| `ProductCategory` | `product_id` | `BIGINT` | 否 | `PK_ProductCategory`（复合）·`FK_ProductCategory_Product` → `Product(product_id)` |
| `ProductCategory` | `category_id` | `BIGINT` | 否 | `PK_ProductCategory`（复合）·`FK_ProductCategory_Category` → `Category(category_id)` |
| `ProductCategory` | `is_primary` | `BIT` | 否 | `DF_ProductCategory_is_primary`（默认 0）·过滤唯一索引 `UQ_ProductCategory_is_primary(product_id) WHERE is_primary = 1`（`01:66`） |
| `Customer` | `customer_id` | `BIGINT` | 否 | `PK_Customer`·`IDENTITY(1,1)` |
| `Customer` | `mobile` | `VARCHAR(20)` | 否 | `UQ_Customer_Mobile` |
| `Customer` | `customer_type` | `VARCHAR(20)` | 否 | — |
| `Customer` | `member_level_id` | `BIGINT` | **是** | `FK_Customer_MemberLevel` → `MemberLevel(member_level_id)`（A 域唯一可空列，I-A05） |
| `Customer` | `current_points` | `INT` | 否 | —（跨表物化派生，§4.1） |
| `Customer` | `status` | `VARCHAR(20)` | 否 | — |
| `ProductBom` | `product_id` | `BIGINT` | 否 | `PK_ProductBom`（复合）·`FK_ProductBom_Product` → `Product(product_id)` |
| `ProductBom` | `ingredient_id` | `BIGINT` | 否 | `PK_ProductBom`（复合）·`FK_ProductBom_Ingredient` → `Ingredient(ingredient_id)` |
| `ProductBom` | `usage_qty` | `DECIMAL(12,3)` | 否 | — |
| `ComboComponent` | `combo_product_id` | `BIGINT` | 否 | `PK_ComboComponent`（复合）·`FK_ComboComponent_ComboProduct` → `Product(product_id)` |
| `ComboComponent` | `child_product_id` | `BIGINT` | 否 | `PK_ComboComponent`（复合）·`FK_ComboComponent_ChildProduct` → `Product(product_id)` |
| `ComboComponent` | `quantity` | `INT` | 否 | — |
| `Promotion` | `promotion_id` | `BIGINT` | 否 | `PK_Promotion`·`IDENTITY(1,1)` |
| `Promotion` | `promotion_name` | `NVARCHAR(50)` | 否 | — |
| `Promotion` | `promotion_type` | `VARCHAR(20)` | 否 | —（`CHECK` 现为单值 `'FIXED_PRICE'`） |
| `Promotion` | `start_at` | `DATETIME2(0)` | 否 | — |
| `Promotion` | `end_at` | `DATETIME2(0)` | 否 | — |
| `Promotion` | `status` | `VARCHAR(20)` | 否 | — |
| `PromotionProductRule` | `promotion_rule_id` | `BIGINT` | 否 | `PK_PromotionProductRule`·`IDENTITY(1,1)` |
| `PromotionProductRule` | `promotion_id` | `BIGINT` | 否 | `FK_PromotionProductRule_Promotion` → `Promotion(promotion_id)` |
| `PromotionProductRule` | `product_id` | `BIGINT` | 否 | `FK_PromotionProductRule_Product` → `Product(product_id)` |
| `PromotionProductRule` | `weekday_no` | `INT` | 否 | — |
| `PromotionProductRule` | `start_time` | `TIME(0)` | 否 | — |
| `PromotionProductRule` | `end_time` | `TIME(0)` | 否 | — |
| `PromotionProductRule` | `promo_price` | `DECIMAL(10,2)` | 否 | — |
| `PromotionProductRule` | `priority` | `INT` | 否 | — |

> 列数量核对：3+5+5+5+3+6+3+3+6+8 = **47**。三张复合主码表的主码列在 `01` 中未逐列写 `NOT NULL`（`01:55`–`01:57`、`01:87`–`01:89`、`01:101`–`01:102`），由主键约束强制非空——与 C 域 `Inventory` 的情形同一口径，不计为可空列。

## 3. 逐表函数依赖与范式分析

每表按 R6-08 的五项给结论：候选码 → 关键 FD → 1NF/2NF/3NF → 三类异常（各附数据例子；无异常写「如何避免」）→ 保留或改动。数据例子取自 `09a` 种子形状或按库结构可构造的合法值。

### 3.1 `Category`（商品分类）

- **业务含义**：一行 = 一个商品分类，`v_active_product_price` 按主分类展示它，菜单分区与统计按它聚合。
- **候选码**：`category_id`（PK）。**`category_name` 业务上应唯一但未声明**——同名分类在展示层无法区分，也没有门店 / 父分类列可以承载「同名不同店」的差异（§4.6）。
- **关键 FD**：`category_id → category_name, status`。`category_name → category_id` 若按业务唯一性声明则成立，届时成为第二个候选码；未声明前它不是 FD（v0.1 允许两行同名，`sp_create_category` 不查重）。
- **范式**：单值列（1NF）；候选码单属性，无部分依赖（2NF）；决定因素均为单属性候选码，达 BCNF。**补不补唯一约束都不改变范式判定**——补了 `category_name` 只是变成第二个单属性候选码。
- **三类异常**：无。避免机制：字典行一处存储，`status` 翻转替代删除（`sp_update_category_status`，`04:205`），全库没有删除过程，因此不存在「删掉分类才发现的重复事实」。唯一残留风险是「同名两行」——它不造成 FD 异常，但造成展示歧义，列入 §4.6 的补声明项。
- **结论**：保留结构；2.2 拟补 `UQ_Category_category_name`（I-A12）。

### 3.2 `MemberLevel`（会员等级）

- **业务含义**：一行 = 一个等级档位（`09a` 种子：普通 0 / 银卡 500 / 金卡 1500），`threshold_points` 是进入该档的累计积分下限，`point_multiplier` 是该档的积分倍率。
- **候选码**：`member_level_id`（PK）；**`threshold_points` 是业务候选码，由过程强制、未声明**——`sp_create_member_level`（`04:1158`–`1160`）与 `sp_update_member_level`（`04:1241`–`1244`）都以 `WITH (UPDLOCK, HOLDLOCK)` 查同门槛并 `THROW 51005`，两处口径一致；`level_name` 业务上应为唯一展示名，未声明。
- **关键 FD**：
  - `member_level_id → level_name, point_multiplier, threshold_points, status`（主码决定全部）；
  - **`threshold_points → level_name, point_multiplier, status`**——成立，证据不是样例而是过程：两个过程无条件拒绝同门槛的第二行（含 `INACTIVE` 行），所以「同门槛必同一行」在所有合法状态成立。
  - `point_multiplier`、`level_name` 互不决定：`09a` 三个等级的倍率两两不同，但样例不重复不能证明依赖（R6-13），业务上也没有「倍率唯一」的规则，**不作候选码**。
- **范式**：1NF/2NF 通过（单属性码）；3NF 按**声明**判定通过（唯一决定因素是主码）；按**业务 FD** 判定也通过——`threshold_points` 一旦被承认为候选码，所有决定因素都是候选码，达 BCNF。两种口径结论一致，这是本表可以放心推进补声明的原因。
- **三类异常**：无。避免机制：等级是纯字典行，`threshold_points` 的唯一性由过程在写入前加锁检查，不会出现「同门槛两个等级」导致等级解析二义；停用等级由 `sp_update_member_level_status`（`04:1282`）翻状态并把受影响顾客的 `member_level_id` 置空，不删行。
- **结论**：保留结构；2.2 拟补 `UQ_MemberLevel_threshold_points`（必做，让已在过程里成立的业务 FD 声明化）与 `UQ_MemberLevel_level_name`（建议）。见 §4.2、§4.6。

### 3.3 `Ingredient`（原料）

- **业务含义**：一行 = 一种可库存原料，`unit_name` 是计量单位，`safety_stock_qty` 是安全库存线（C 域的补货判定读它）。
- **候选码**：`ingredient_id`（PK）；`(ingredient_name, unit_name)` 业务上应唯一（§4.6），未声明。
- **关键 FD**：`ingredient_id → ingredient_name, unit_name, safety_stock_qty, status`。`(ingredient_name, unit_name)` 是否决定其余属性取决于业务唯一性，同 3.1。`safety_stock_qty` **不是派生值**：它由人工设定（`sp_create_ingredient` / `sp_update_ingredient` 直接写入，`04:255` / `04:305`），不由库存流水或销量算出，因此不构成「由别处汇总」的冗余。
- **范式**：1NF/2NF/3NF 通过，达 BCNF。
- **三类异常**：无。避免机制：字典行一处存储；被 `ProductBom`、`Inventory`、`ReplenishmentSuggestion`、`PurchaseOrderItem` 引用的是 `ingredient_id`（后三者属 C 域），改名只改一行，不会在子表留下旧名（名称本就不冗余存储）；停用不删除。
- **结论**：保留结构；2.2 拟补 `UQ_Ingredient_name_unit (ingredient_name, unit_name)`（I-A12）。

### 3.4 `Product`（商品与套餐）

- **业务含义**：一行 = 一个销售单元，`product_type` 区分单品 / 套餐，`base_price` 是当前标准价（可变，历史成交价在 B 域的 `SalesOrderItem.unit_price` 里冻结，I-A02）。
- **候选码**：`product_id`（PK）；`product_name` 业务上应唯一（§4.6），未声明。
- **关键 FD**：`product_id → product_name, base_price, product_type, status`。`product_type` **不决定** `base_price` 或 `status`（同一类型下价格各异：`09a:59`–`64` 的六个商品中五个 `SINGLE` 基价 9.00–19.00、一个 `COMBO` 45.00），不是 FD 问题而是「类型决定可配 BOM / 可配套餐组成」的条件完整性约束，由 `sp_set_product_bom`、`sp_set_combo_component` 过程校验（`04:559`–`570`、`04:755`–`765`）。
- **范式**：1NF/2NF/3NF 通过，达 BCNF。
- **三类异常**：无。避免机制：`base_price` 是可变的「当前价」，改价由 `sp_update_product_price` 单点写入；历史价不本域存储，故不存在「同价存两处」的更新异常。若按教学原文的示例把 `category_name` 并进本表才会出现传递依赖——本设计把分类放在关系表 `ProductCategory`，正是为了避开它（§4.4）。
- **结论**：保留结构；2.2 拟补 `UQ_Product_product_name`（I-A12）。

### 3.5 `ProductCategory`（商品分类关系表）

- **业务含义**：一行 = 一次「商品 × 分类」的归属，`is_primary` 标记它是不是该商品的展示分类；一个商品可属多个分类，至多一个主分类。
- **候选码**：`(product_id, category_id)`（复合 PK）。**复合主码即唯一候选码**；过滤唯一索引 `UQ_ProductCategory_is_primary` 是部分唯一，不是候选码（§4.5）。
- **关键 FD**：`(product_id, category_id) → is_primary`，完整依赖整个键。
  - `product_id ↛ is_primary`：反例在种子——商品 3 有两行 `(3,2,1)` 与 `(3,1,0)`（`09a:71`），同一 `product_id` 对应不同的 `is_primary`。
  - `category_id ↛ is_primary`：反例同样在种子——分类 1 下有 6 行，既有 `is_primary=1` 也有 `is_primary=0`（`09a:69`–`74`）。
  两个方向都有反例，**不是部分依赖**。这一点必须写明：只看 `is_primary` 的取值分布（每商品至多一个 1）会误判为「主分类是商品属性」，但主分类只能由「哪一行」确定，不是由 `product_id` 单独确定。
- **范式**：1NF/2NF/3NF 通过（复合主码关联，非主属性完整依赖整个键），达 BCNF。
- **三类异常**：无。避免机制：归属事实只存一处，插入 / 删除一行只影响该「商品—分类」对；商品或分类被引用时外码拒绝删除（全库无删除过程，改为状态翻转），所以不存在「删分类后留下孤儿归属」。
- **结论**：保留（I-A10 的第一项）。

### 3.6 `Customer`（顾客）

- **业务含义**：一行 = 一位顾客；`mobile` 是登录式检索键（顾客端以手机号 + 取餐码双要素识别，见 `application-contract.md` §1），`member_level_id` 是当前等级，`current_points` 是累计积分。
- **候选码**：`customer_id`（PK）、`mobile`（`UQ_Customer_Mobile`，`01:75`），两个单属性候选码。
- **关键 FD**：
  - `customer_id → 全部属性`；`mobile → 全部属性`（唯一约束使然）。
  - **`current_points` 是跨表物化值**：它可由 `PointLedger` 的 `EFFECTIVE` 流水加总再加期初余额推出（§4.1），但这是**跨关系的派生**，不是本关系内的传递依赖。
  - **`member_level_id` 不由 `current_points` 决定**——若成立就会构成 `customer_id → current_points → member_level_id` 的传递依赖并违反 3NF。它**不成立**，反例有两条（§4.2）：等级停用会把受影响顾客置空（`04:1326`–`1332`），于是同积分的两位顾客可一位有等级、一位为空；新增 / 调整门槛不回溯已有顾客，直到下一次积分入账才重算。
- **范式**：1NF 通过；2NF 通过（单属性候选码，无真子集）；3NF 通过（决定因素均为候选码，`member_level_id` 与 `current_points` 之间无 FD）。**判定依赖 §4.2 的反例**，这是本表分析的关键一步。
- **三类异常**：无。避免机制：`mobile` 唯一使「同一顾客建两次档」被拒（`sp_create_customer` 加锁查重后 `THROW 51005`，`04:1392`）；无删除过程；积分只增不减（`CK_PointLedger_point_delta` 与 `sp_apply_customer_points` 都要求 `point_delta >= 0`），`current_points` 不会出现负数或回退写法不一致。
- **结论**：保留（I-A08：保留 `current_points` 物化，维护口径见 §4.1）。

### 3.7 `ProductBom`（商品用料表）

- **业务含义**：一行 = 「某单品每卖一份消耗某原料多少」，是 B / C 锁库存与扣减的展开依据（经 `v_product_bom_detail`）。
- **候选码**：`(product_id, ingredient_id)`（复合 PK，非主属性 1 个）。
- **关键 FD**：`(product_id, ingredient_id) → usage_qty`，完整依赖全键。两个方向**都有反例**：
  - `product_id ↛ usage_qty`：商品 1 消耗四种原料，用量 1.000 / 1.000 / 30.000 / 20.000（`09a:78`）；
  - `ingredient_id ↛ usage_qty`：原料 3（生菜）被商品 1 / 2 / 6 使用，用量 30.000 / 20.000 / 120.000（`09a:78`–`82`）。
  两者都是候选码的真子集且不决定非主属性，无部分依赖。
- **范式**：1NF/2NF/3NF 通过（复合主码，非主属性完整依赖整个键），达 BCNF。
- **三类异常**：无。避免机制：一条「用量」事实恰好一行，改用量只改该行；同一原料不可能在同一个商品的 BOM 里出现两行（复合主码拒绝），`sp_set_product_bom` 另有 JSON 内重复检查（`04:653`–`654`，`THROW 51005`）。
- **结论**：保留（I-A10 的第二项）。

### 3.8 `ComboComponent`（套餐组成）

- **业务含义**：一行 = 套餐中的一个子项及其份数（`09a` 的套餐 5 = 商品 1 ×1 + 商品 2 ×1 + 商品 4 ×2）。
- **候选码**：`(combo_product_id, child_product_id)`（复合 PK，非主属性 1 个）。`child_product_id` 单独**不是**候选码：同一商品可同时是多个套餐的子项。
- **关键 FD**：`(combo_product_id, child_product_id) → quantity`。
  - `combo_product_id ↛ quantity`：反例是套餐 5 的三个子项份数 1 / 1 / 2（`09a:89`–`91`）。
  - `child_product_id ↛ quantity`：**种子里没有反例**（三个子项各自只出现在套餐 5），但按 R6-13 不能据此认定 FD 成立——业务上同一子项可被不同套餐以不同份数引用，构造反例即成立（如另一套餐把商品 4 记为 ×3）。这正是「样例无重复不等于依赖成立」的典型条目。
  两个方向都不构成部分依赖。
- **范式**：1NF/2NF/3NF 通过（复合主码，非主属性完整依赖整个键），达 BCNF。
- **三类异常**：无。避免机制：一条组成事实一行；自引用形状的两个外码都指向 `Product`，但 `child_product_id = combo_product_id`（套餐包含自己）由 `sp_set_combo_component` 拒绝（`04:759`），JSON 内重复子项也被拒（`04:761`–`762`）——这是完整性约束，不是 FD。
- **结论**：保留（I-A10 的第三项）。

### 3.9 `Promotion`（促销活动）

- **业务含义**：一行 = 一次促销活动（有效期区间 + 类型 + 状态），规则行在 `PromotionProductRule`。
- **候选码**：`promotion_id`（PK）。**无业务候选码**：`promotion_name` 允许同名跨期（同名的「疯狂星期四」每隔一段时间重开是正常业务），`(promotion_name, start_at)` 也可能因同日两场而重复，业务未声明任何唯一性。
- **关键 FD**：`promotion_id → promotion_name, promotion_type, start_at, end_at, status`。`promotion_type` 现由 `CHECK` 限定为单值 `'FIXED_PRICE'`（`04:136`）——单值枚举不产生 FD（它不决定任何其他属性），日后扩类型也不改变范式。
- **范式**：1NF/2NF/3NF 通过，达 BCNF。
- **三类异常**：无。避免机制：活动头与规则行分离，改活动有效期只改一行；同名跨期不构成冗余（两行的起止时间不同，是不同的活动事实）。
- **结论**：保留；**不补** `promotion_name` 唯一约束（§4.6）。

### 3.10 `PromotionProductRule`（促销活动明细）

- **业务含义**：一行 = 一条「某活动在某星期某时段对某商品的一口价」，`priority` 越大越优先；同一商品同一时刻命中多条时由定价函数取一条。
- **候选码**：`promotion_rule_id`（PK）。**自然键 `(promotion_id, product_id, weekday_no, start_time, end_time)` 不成立**：种子里 1、2 号规则的活动、商品、星期、时段完全相同，只有一口价与优先级不同（`09a:117`–`118`）——这正是优先级演示的数据，不是录入重复。
- **关键 FD**：`promotion_rule_id → promotion_id, product_id, weekday_no, start_time, end_time, promo_price, priority`。`priority` **不决定** `promo_price`（反例：种子里优先级 10 → 9.90、5 → 12.00，同一优先级在不同规则下价格也可不同），不是 FD 问题。
- **范式**：1NF/2NF/3NF 通过（单属性码），达 BCNF。
- **三类异常**：无。避免机制与判定依据：
  - **不重复存事实**：同窗口多行是「优先级链」，各行的 `promo_price` / `priority` 是独立事实，不是同一事实存两处；
  - **取值确定**：定价函数 `fn_get_effective_product_price` 用 `ORDER BY r.priority DESC, r.promotion_rule_id ASC` 取 `TOP (1)`（`04:46`），同窗多行的结果唯一且可复现；
  - **低优先级同窗行是备用行**：只在更高优先级的同窗规则被删 / 停用后才生效——`04` 的 18 个过程只有 create / update / set 三类，全库没有删除规则的过程，所以这条链不会自己消失，它不是死数据；
  - 若在窗口上强加唯一约束，反而会挡掉种子里的演示行与「同窗多档价」这一设计意图。
- **结论**：保留；**不补**窗口唯一约束（§4.6）。可选的过程层查重（同活动 + 同商品 + 同星期 + 同窗口 + 同优先级才算重复）记入 2.2 的可选项，不列为必做。

## 4. 跨表观察与待定项收口（I-A08–I-A12）

### 4.1 `Customer.current_points`：跨表物化派生，保留（I-A08 结论）

**事实**：`current_points` **可由 B 域 `PointLedger` 的 `EFFECTIVE` 流水加总推出，但必须再加一个期初余额**——从零开始的总和并不成立。两条路径在同事务内原子：

- 建流水时是 `PENDING`，**不计入**积分（`05:314` 插入，`ledger_status` 默认 `PENDING`）；
- 只有完成 / 送达 / 自提的过程才把流水翻成 `EFFECTIVE`，并**紧接着**调用 A 的 `sp_apply_customer_points` 加同一 `point_delta`（`05:476`–`479`，另两处同形）；
- 状态守卫要求「恰好一条 `PENDING`」才允许完成（`THROW 52502`），因此同一笔流水不会加两次；
- `VOIDED` 只可能从 `PENDING` 转来（`05:689`），作废的流水**从未计入**积分，所以取消 / 退款不需要扣回，也不会让汇总式与物化值产生差额。

**期初余额是真实存在的，不能省。** `09a` 给顾客 2、3 直接写入 `current_points` 500 / 1500（`09a:99`–`100`），而 `PointLedger` 没有任何对应流水——`09b` 只对流水做断言、不插入流水行。因此正确的关系是 `current_points = 期初 offset + SUM(point_delta WHERE EFFECTIVE)`。若把等式写成纯汇总，在种子数据上对顾客 2、3 会直接差 500 / 1500，断言必然失败。

**结论：保留物化**，与 B 的 `SalesOrder.total_amount` 同一口径（两者都是「可由明细汇总、但读取频繁」的值，都保留并写明维护机制，而不是一方派生一方物化）。理由：

1. 等级解析（`sp_apply_customer_points` 每次入账重算）与顾客查询都要读它，每次 `SUM` 全流水随订单量线性变慢；
2. 维护点唯一且同事务——除建档时 `sp_create_customer` 写 0（`04:1409`）之外，唯一的增量写入口是 `sp_apply_customer_points`（`04:53`–`103`）；`08:153` 另对 7 个业务角色 `DENY UPDATE ON dbo.Customer (current_points)`，直接改列被挡，而过程经所有权链不受该 `DENY` 限制（第一阶段已实测，`c-issues.md`），所以「谁能改这一列」在权限层也收成一条路。该过程只动 `Customer`、不碰 `PointLedger`，配对写由 B 的完成过程负责，属阶段一已冻结的跨域接口；
3. SQL Server 没有可表达「跨表汇总」的声明式约束（无物化视图 / 断言），所以「加约束保证一致」这条路不存在，只能在回归里验证。

**2.2 落地**：基线脚本按顾客捕获三元组 `(current_points, SUM(EFFECTIVE point_delta), current_points − SUM)`，第三项即期初 offset。按 `09a` / `09b` 的种子现场，顾客 1 有订单完成产生的真实流水、offset 为 0，顾客 2、3 没有对应流水、offset 分别为 500 / 1500。`13a` 的一致性断言分两条：**变动对账**——迁移后 `current_points − SUM(EFFECTIVE)` 必须与基线相等；**期初登记**——该差额必须等于基线脚本登记的期初 offset，不允许出现「用补造流水抹平差额」的做法。同时在数据字典写明「`current_points` 是物化派生列，不得直接 `UPDATE`」。**不删除该列改实时汇总**：那会让 A 的读路径反向依赖 B 的流水表，跨域放大，且顾客端查单会随订单量变慢。

### 4.2 `MemberLevel` 与升级规则：没有传递依赖，但有两条必须写死的口径（I-A09 结论）

**结论一：本域不存在「等级由积分派生」的传递依赖。** 若 `current_points → member_level_id` 成立，`Customer` 就有 `customer_id → current_points → member_level_id`，3NF 不成立。它**不成立**，两条反例都在源码里：

1. **等级停用置空**：`sp_update_member_level_status` 把受影响顾客的 `member_level_id` 置为 `NULL`（`04:1326`–`1332`）。置空后，两位积分完全相同的顾客可以一位有等级、一位为空——同样的 `current_points` 对应不同的 `member_level_id`，FD 被打破。
2. **不回溯**：新增等级或调整 `threshold_points` 不会重算已有顾客；`member_level_id` 只在下一次 `sp_apply_customer_points` 调用时按新门槛重算（`04:86`–`95`）。因此在两次入账之间，同积分的顾客可以分别停在旧档与新档。

**结论二：`threshold_points` 的业务唯一性是等级解析正确的前提，应声明化。** 等级解析是「取 `threshold_points <= 积分` 的启用档里门槛最大的一条」（`04:91`–`95`，建档时同判据 `04:1398`–`1410`），若两个启用档门槛相同，解析结果就退化为按 `member_level_id` 兜底，业务上不可接受。该唯一性已由两个过程强制（`THROW 51005`），但直接 `INSERT` 可绕过。2.2 补 `UQ_MemberLevel_threshold_points`，只声明既有事实，不改数据。

**结论三（冻结事项）：**「加等级 / 调门槛不回溯已有顾客」是**预期行为**，不是缺陷——写进数据字典，避免 2.2 有人把它当 bug 改掉，从而把 `member_level_id` 真正变成传递依赖。

### 4.3 三个复合主码表：无部分依赖、无 3NF 问题（I-A10 结论）

| 表 | 候选码 | 非主属性 | 对候选码真子集的部分依赖 | 判定 |
| --- | --- | --- | --- | --- |
| `ProductCategory` | `(product_id, category_id)` | `is_primary` | 无：两个方向都有反例（§3.5） | 2NF/3NF 通过 |
| `ProductBom` | `(product_id, ingredient_id)` | `usage_qty` | 无：两个方向都有反例（§3.7） | 2NF/3NF 通过 |
| `ComboComponent` | `(combo_product_id, child_product_id)` | `quantity` | 无：父项方向有反例；子项方向按业务规则可构造反例（§3.8） | 2NF/3NF 通过 |

三表**都不是全码表**（全码＝候选码包含全部属性，见文首术语定义）：每张表各有一个非主属性（`is_primary` / `usage_qty` / `quantity`），它由「哪一对」整体确定，且两个方向的真子集都有反例，因此不存在部分依赖。三表也都不含可传递的非主属性（没有「非主属性决定非主属性」的结构），所以 3NF 同样通过。结论写全而不是省略，是因为「没有异常」本身是 R6-15 要求的交付结论。

> **2026-10-27 订正**：本节初稿把这三张表称作「全码」，与文首「全码＝候选码包含全部属性」的定义矛盾——它们各有非主属性。B 在 `b-delivery-handoff.md` §2 复核时指出，本处按定义改写。「无部分依赖」的结论不变，但理由从「非主属性为空集」更正为「非主属性完整依赖整个复合码」，两个方向的种子反例见 §3.5 / §3.7 / §3.8。

### 4.4 「商品→类别→类别名」示例：本项目不构成该传递依赖（I-A11 结论）

教学原文用「商品编号 → 类别编号 → 类别名称」举例传递依赖。本项目的实际结构是：

- 商品与分类是 **M:N**，归属存在 `ProductCategory` 里，`Product.product_id` **不单值决定** `category_id`——反例在种子：商品 3（薯条(中)）同属分类 2（主）与分类 1（次）（`09a:71`）；
- 因此「`product_id → category_id → category_name`」这条链在 v1.0 里根本不存在，`Product` 表也没有 `category_name` 列可冗余；
- 真正需要声明的是「每商品至多一个主分类」，它已由过滤唯一索引表达（§4.5）。

**结论：不为凑示例把 `ProductCategory` 拆开或并入 `Product`。** R6-05 要求的传递依赖演示，按 R6-15 的口径放在 2.2 的重构方案里用**独立示例关系**做（例如 `DEMO_ProductFlat(product_id PK, product_name, category_id, category_name)`，配一条插入 / 修改 / 删除异常的数据例子和 `DEMO_Product` + `DEMO_Category` 的无损分解），不进入 v1.0 的 25 表结构。该示例的 DDL 与论证归 2.2 的 `refactoring-design.md`（B 主笔），A 只提供本域的「为何不适用」依据。

### 4.5 过滤唯一索引不是函数依赖（`UQ_ProductCategory_is_primary`）

`UQ_ProductCategory_is_primary ON ProductCategory(product_id) WHERE is_primary = 1`（`01:66`）表达「每商品至多一个主分类」。它**不是候选码**，也不是 FD：

- 它只约束 `is_primary = 1` 的**子集**，而候选码必须对全表成立；
- `product_id ↛ is_primary`（反例：商品 3 的两行 `1` / `0`，§3.5），所以 `product_id` 不是候选码；
- 它也不表达「每商品至少一个主分类」——那是 `sp_create_product` 建档即写一条主分类的过程保证（`04:413`；`@category_id` 为空即 `THROW 51000`，`04:377`），与 ER 图 r2 的标签口径一致（`a-issues.md` §6.1 第 3 条）。

分析范式时不得把「过滤条件下的唯一」读成候选码，这一点与 C 域 `UQ_ReplenishmentSuggestion_ingredient_id`（仅约束开放建议）同一陷阱。

### 4.6 六张表无声明式候选码：逐表判定（I-A12 结论）

**先订正一处计数**：`a-issues.md` I-A12 标题原写「七张表」，正文实际只列 6 张——`Customer` 有 `UQ_Customer_Mobile`（`01:75`），不属此列。本文按 **6 张**分析，`a-issues.md` 已同步订正。

判定原则：名称列是否应唯一，取决于**重名是否造成不可区分的歧义**，而不是「主数据都该唯一」：

| 表 | 名称 / 业务键 | 业务上应否唯一 | 结论 |
| --- | --- | --- | --- |
| `Category` | `category_name` | 是：菜单分区按它展示，没有门店 / 父分类列承载同名差异 | 2.2 补 `UQ_Category_category_name` |
| `MemberLevel` | `threshold_points` | **是，且是正确性前提**：同门槛两档会让等级解析二义（§4.2） | 2.2 补 `UQ_MemberLevel_threshold_points`（**必做**） |
| `MemberLevel` | `level_name` | 是：等级只按名称展示 | 2.2 补 `UQ_MemberLevel_level_name`（建议，低风险） |
| `Ingredient` | `(ingredient_name, unit_name)` | 组合唯一：同名不同单位（如「生菜」按片 / 按克）是合法规格差异，同名同单位才重复 | 2.2 补复合 `UQ_Ingredient_name_unit` |
| `Product` | `product_name` | 是：菜单与顾客端都只显示名称，同名商品无法区分；改配方复用同一 `product_id`（历史订单按 id 引用），不靠新建同名行 | 2.2 补 `UQ_Product_product_name` |
| `Promotion` | `promotion_name` | 否：跨期活动同名是正常业务（同名「疯狂星期四」多次开） | **不补** |
| `PromotionProductRule` | 无名称列；窗口自然键不成立 | — | **不补**唯一约束（§3.10） |

**数据可行性**：以上五个待补声明在 `09a` 种子上均无重复值（2 个分类、3 个等级、5 种原料、6 个商品），迁移不会因存量数据失败；若 2.2 之前有人录入过重名，`11a` 的迁移脚本须先查重并报出清单，不得静默失败（计划 §5.1 口径）。

## 5. 2.2 动作清单与冻结事项

| # | 事项 | 性质 | 落点 | 回归（`13a`） |
| --- | --- | --- | --- | --- |
| 1 | 补 `UQ_MemberLevel_threshold_points`（I-A09 / I-A12，必做） | 候选码声明（域内） | `11a`、字典 | 插入同门槛第二档被 `2601/2627` 拒绝 |
| 2 | 补 `UQ_Category_category_name` | 候选码声明（域内） | `11a` | 同上 |
| 3 | 补 `UQ_Product_product_name` | 候选码声明（域内） | `11a` | 同上 |
| 4 | 补 `UQ_Ingredient_name_unit (ingredient_name, unit_name)` | 候选码声明（域内） | `11a` | 同上（同名单单位允许） |
| 5 | 补 `UQ_MemberLevel_level_name`（建议） | 候选码声明（域内） | `11a` | 同上 |
| 6 | 其余 5 表（含 3 张复合主码表、`Customer`、`PromotionProductRule`） | **无需结构变更**（R6-15 口径记录） | — | 兼容断言沿用第一阶段口径 |
| 7 | 冻结事项 A | `Customer.current_points` 定性为「期初 offset + 跨表物化增量」，唯一维护入口 `sp_apply_customer_points`；禁止直接 `UPDATE`，也禁止用补造流水抹平期初 | 数据字典 §顾客 | §4.1 的变动对账 + 期初登记两条断言 |
| 8 | 冻结事项 B | `Customer.member_level_id` 语义：当前快照，等级停用置空，加档 / 调门槛不回溯 | 数据字典 §会员 | 停用置空与不回溯各一条 |
| 9 | 冻结事项 C | `PromotionProductRule` 同窗多行合法，按 `priority DESC, rule_id ASC` 取一 | 数据字典 §促销 | 同窗两档价取高优先级 |
| 10 | 独立示例关系（R6-05 传递依赖演示） | 教学演示，**不进 v1.0 结构** | `refactoring-design.md` | — |

**不做的事项**（论证已给出，不留悬念）：拆 `ProductCategory` 或把分类并入 `Product`（§4.4，会造出真传递依赖）；删除 `current_points` 改实时汇总（§4.1，跨域读放大）；给 `Promotion.promotion_name` 补唯一（§4.6，同名跨期合法）；给规则窗口补唯一（§3.10，会挡掉设计内的同窗多档价）；把三张关联表合并（§1 末段）。

## 6. 验证记录

**当前状态：草案，人工逐表复核尚未完成（2.1 收口前补）。** 已完成的部分：

1. **结构事实对账（脚本）**：§2 的 47 行属性与键清单与 `sql/01_master_schema.sql` 逐项比对（表名、列名、类型、可空性、主键 / 唯一键 / 外键 / 默认值约束名、过滤唯一索引、`IDENTITY`），并与 `sql/04` 的 22 条命名 `CHECK` 交叉核对。**终轮 0 差异、退出码 0**；脚本 `result/stage2/scripts/check_a_norm.py`，输出归档 `result/stage2/a-normalization-check-2026-10-21.txt`（含首轮差异与归因——首轮 7 项差异全部是脚本判据缺陷，文档侧未改）。
2. **数据例子对账**：§3、§4 引用的种子行（商品 3 双分类、原料 3 在三个商品的不同用量、套餐 5 的三子项份数、1/2 号规则同窗不同价、三位顾客积分 0/500/1500）已逐条回到 `09a` 核对行号。
3. **过程依据对账**：`sp_create_member_level` / `sp_update_member_level` 的 `51005` 查重（`04:1158`–`1160`、`04:1241`–`1244`）、`sp_create_customer` 的默认档判据（`04:1398`–`1410`）、`sp_update_member_level_status` 的置空（`04:1328`）、定价函数的排序（`04:46`）、`sp_apply_customer_points` 的重算（`04:86`–`95`）均已回源码确认。
4. **2026-10-27 交叉复核订正（B 提出，A 采纳）**：① 三张复合主码表原称「全码」与本文件文首定义矛盾，已按定义改写，见 §4.3 订正说明；② `current_points` 原写「可完全由 `PointLedger` 推出」及据此的 `13a` 纯汇总断言不成立——`09a` 给顾客 2、3 写有 500 / 1500 期初、无对应流水，已改为「期初 offset + 增量」并重写断言，见 §4.1。两处均为文档侧事实错误，源码与种子数据未动。
5. **待补**：三人交叉复核（B 汇总时确认 FD 口径、C 合图时确认实体键列）；`a-issues.md` I-A08–I-A12 的结论文本回填（2026-10-21 已加指针，完整措辞待 2.1 收口统一）；§3、§4 与 B 的 `business-rule-mapping.md` 的交叉引用。
