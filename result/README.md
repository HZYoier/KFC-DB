# 第一阶段测试结果

执行日期：2026-10-01

实例：`localhost\MSSQLSERVER2`

成员 C 的独立复验在同日于 `.\SQLEXPRESS` 复跑，结果与下表一致；其原始输出见本目录 `*-c-2026-10-01.txt`。

入口：`sql/run_all.sql`

## 结果摘要

| 验收域 | 结果 |
| --- | --- |
| A：主数据、定价与会员 | `pass=13 fail=0` |
| B：订单、支付与履约 | `pass=15 fail=0` |
| C：库存、补货、权限与集成 | `pass=17 fail=0` |
| 完整日志中的 PASS 行 | 46 |
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
```
