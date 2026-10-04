# 第一阶段测试结果

执行日期：2026-10-01（基线）；2026-10-03 由成员 A 在第三台机器上重跑，见下文

实例：`localhost\MSSQLSERVER2`（基线）；`localhost` / `DESKTOP-TSLV34Q`（成员 A 复跑）

成员 C 的独立复验在同日于 `.\SQLEXPRESS` 复跑，结果与下表一致；其原始输出见本目录 `*-c-2026-10-01.txt`。

成员 A 于 2026-10-03 在默认实例上从空库重跑。该轮为 `10c` 增加了 T14，因此下表采用本轮数字（`10c` 18 条）；`2026-10-01` 的基线是 `10c` 17 条、46 条 `PASS`，本目录保留的 `*-2026-10-01.txt` 即那一轮的原始输出。

入口：`sql/run_all.sql`

## 结果摘要

| 验收域 | 结果 |
| --- | --- |
| A：主数据、定价与会员 | `pass=13 fail=0` |
| B：订单、支付与履约 | `pass=15 fail=0` |
| C：库存、补货、权限与集成 | `pass=18 fail=0` |
| 完整日志中的 PASS 行 | 47 |
| SQL 错误行 | 0 |
| 跨域接口契约 | PASS |

## 证据文件

- `stage1-full-test-2026-10-01.txt`：从空数据库执行 `run_all.sql` 的完整原始输出。
- `stage1-contract-check-2026-10-01.txt`：只读跨域接口对象与签名检查输出。
- `stage1-object-inventory-2026-10-01.txt`：数据库对象数量清点。
- `stage1-full-test-summary-2026-10-01.png`：从原始结果整理的终端风格结果图。

成员 C 的独立复验（`.\SQLEXPRESS`，UTF-8 编码）：

- `stage1-full-test-c-2026-10-01.txt`：空库执行 `run_all.sql` 的完整原始输出（`exit=0`，46 条 `PASS`、0 条「消息」错误行，三条验收 `13`/`15`/`17`）。
- `stage1-receiving-invariants-c-2026-10-01.txt`：收货链不变量断言 `t10`（9 条，`pass=9 fail=0`）。
- `stage1-receiving-boundaries-c-2026-10-01.txt`：收货过程边界断言 `t10b`（18 条，`pass=18 fail=0`）。
- `stage1-regression-c-2026-10-01.txt`：四条夹具链回归汇总（144 条断言 0 FAIL；`08` 连跑两遍幂等；`09c` 重跑被 `THROW 51001` 拒绝）。

成员 A 的独立复验（`localhost` / `DESKTOP-TSLV34Q`，默认实例，SQL Server 17.0.1000.7 Express Edition）：

- `stage1-full-test-a-2026-10-03.txt`：空库执行 `run_all.sql` 的完整原始输出（`exit=0`，47 条 `PASS`、0 条「消息」错误行，三条验收 `13`/`15`/`18`）。
- `stage1-contract-check-2026-10-03.txt`：只读跨域接口检查输出（`PASS`，`exit=0`）。该输出是确定性的，与 `2026-10-01` 那份逐字节相同（SHA-256 一致），可佐证本轮改动未触及任何跨域接口。

成员 A 2026-10-04 的建库留证（同一实例，为「成功建库」截图再跑一轮）：

- `stage1-full-test-a-2026-10-04.txt`：删库后从空库整跑的完整原始输出，`exit=0`，47 条 `PASS`、0 条「消息」错误行，三条验收 `13`/`15`/`18`。该文件与 `2026-10-03` 那份逐字节相同（SHA-256 一致）：`run_all.sql` 的输出是确定性的，跨日期、跨机器的复跑结论一致，同时也没有引入新的编译告警。

成员 A 的操作截图（`localhost` / `DESKTOP-TSLV34Q`，2026-10-04），共 19 张，文件名形如 `stage1-a-*-2026-10-04.png`：覆盖成功建库、CRUD（建分类、改价、改配方、改套餐、建促销）、关键查询（定价视图与函数对照、Q-A2 单品与套餐两个分支）、两个视图本体、越权访问（`229` 与 `51004`）、非法数据（`51000` / `51005` / `51003` 两类，以及绕过过程直写撞原生约束的 `547` / `2627`）、对象清点与角色权限矩阵。逐张说明见 `docs/stage1-a-stage-report.md` 第 6.1 节。写操作截图均以 `BEGIN TRANSACTION … ROLLBACK` 收尾，未改动库中数据。

其中建库一张取自 `sqlcmd -o` 写出的 UTF-8 日志（见上一条），并非 SSMS 窗口；其余 18 张为 SSMS 内执行所得。

## SHA-256

```text
095E7702030B4650F66B4C91B696D48E35FC63BB4E26BC7263EAC5C0121EBACD  stage1-full-test-2026-10-01.txt
C59640ED85A8179C8BECBD1F4E48600170DB1CA480D8953B1F9F4E6085CC772E  stage1-contract-check-2026-10-01.txt
D14FE63E93349A38B3539D8257EC037A2607FB5D0C95ABF728C6B4F06B39E467  stage1-object-inventory-2026-10-01.txt
59B5B405CDC23B0B2E3989C3385488F9F7A22F0896F169FE754D40E94FCC72FD  stage1-full-test-summary-2026-10-01.png
5ECD94ECCCF28AE4497F84E19BA97AE10E64A8576503C735F338CB2AC41A1632  stage1-full-test-c-2026-10-01.txt
9AF52578E9145296EAE7A7B4F1C47F458288D7D30D73643C6BE49C1241D0A621  stage1-receiving-invariants-c-2026-10-01.txt
3EE72F51EBEB68EAD3125F988568982DC57215559C790DE0DC6F5327C90DB4F9  stage1-receiving-boundaries-c-2026-10-01.txt
01D205192B189E1C82C15719D65EF7E7CC229348C7F9D0A83D767CA55D1DC00A  stage1-regression-c-2026-10-01.txt
5488448099DB95542747BD42336D241245964C4A57C63041FC5C3385F57C3226  stage1-full-test-a-2026-10-03.txt
C59640ED85A8179C8BECBD1F4E48600170DB1CA480D8953B1F9F4E6085CC772E  stage1-contract-check-2026-10-03.txt
5488448099DB95542747BD42336D241245964C4A57C63041FC5C3385F57C3226  stage1-full-test-a-2026-10-04.txt
C51A21D4B9F4BCF565F0C89039292C450FE2D71A208C1A163F6057BECB2075D5  stage1-a-create-database-2026-10-04.png
4CD47990728BBA0F32C9A7A6E9A63FB9EF993838F4255B5D71D434A77AEEEF07  stage1-a-crud-create-category-2026-10-04.png
26DFC0E06FC621E9261C1AAF828C7BF17F691FC229E927E74EDECF4D6C669C68  stage1-a-crud-create-promotion-2026-10-04.png
C6AD621AFCA8AD79069B1387EE904AD0536FAD0B30E56CC5FB53362CC68CA467  stage1-a-crud-set-bom-2026-10-04.png
98749C535D0622E385CFAA3D3117CB8CC71C1EE2728F0696BB92F3B9E0927B87  stage1-a-crud-set-combo-component-2026-10-04.png
80337B2696BBEA209926F2F84739A55CC1A4CB3CF33CB4EC8E3F2E58B0B24A8D  stage1-a-crud-update-price-2026-10-04.png
1AA1B796C212ECE6BD4A64EDC91737F4510B5D26180ECCE8DDCFC7518525E051  stage1-a-denied-select-category-2026-10-04.png
7B13C255A3EA3B7A24817C18A3DC591ADAFF2181AFD4C6C47F0F34A9D77E3CA6  stage1-a-object-inventory-2026-10-04.png
89A3FE39CA5BAB97BC96E35BC4BDB347448FCC76195042EF55A5802DD6108D41  stage1-a-permission-matrix-2026-10-04.png
BBBF570E896AABFD37E0A72B93BBB7AEBE30380EAD127ECB35B0EC868634BCA4  stage1-a-pricing-view-vs-function-2026-10-04.png
DFED790D8E33683128AF1CD08C82E4F74F039679F69684E4B7CE9BB3A5A416EB  stage1-a-query-q-a2-bom-combo-2026-10-04.png
47A5989D6596679D668256232A74F199FEDBD502AFC1FF694459A152F8558826  stage1-a-query-q-a2-bom-single-2026-10-04.png
15D3ECED152AAF9BC86F9C671FC9BB8B0D220AEEDC9F5B9A28C13F9199067815  stage1-a-reject-51000-negative-price-2026-10-04.png
6699A04218FBAB8B2C5A580F7958C8D8BA79F1567F2ED442E03AEE66EE722981  stage1-a-reject-51003-activate-without-bom-2026-10-04.png
AEFC80460B41E0CC4FEF72C17ECB8E0F0C444DC30AA334BDA0D94509CF6574E7  stage1-a-reject-51003-bom-on-combo-2026-10-04.png
CDE135D00A9104A7E67171886A9D57BFC1626ABE5B910298F2C24C8D282562F8  stage1-a-reject-51004-unmapped-principal-2026-10-04.png
18316149CDB54213451E23AA690648FCDF637A9284E3184BC039D0F33B05E1EE  stage1-a-reject-51005-duplicate-mobile-2026-10-04.png
A1EAC3FAE337A3FAF8A96A9DC6A3F20040B1D972BAF6410429EE115BDFB3C45D  stage1-a-reject-547-check-constraint-2026-10-04.png
D286FCC69445164C341EB519FABBC1CC4E924B2B9F56BB165E7D05FFDD4A19FE  stage1-a-views-2026-10-04.png
```
