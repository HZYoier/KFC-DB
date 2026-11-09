# stage2 证据（C 侧）

隔离实验执行日期：2026-10-13（重跑捕获；实验首做于 2026-10-10，本次为归档要求下的完整复现）；文档对账证据增补于 2026-10-15；ER 子图复核证据增补于 2026-10-17；合并总图对账、B 图复核与契约授权核对增补于 2026-10-27；2.2 基线采集框架证据增补于 2026-10-30；真实 25 表采集、11c 扩展与 12/13c/run_migration 部分演练证据增补于 2026-11-03；OI-16 复核与 OI-17 修复证据增补于 2026-11-06；A 的 register、53513 预演与 common 18/96 证据增补于 2026-11-07；真实 11b 迁移、六套 106/0 与顾客页证据增补于 2026-11-09。

实例：`.\SQLEXPRESS`（SQL Server 2025 Express 17.0.1000.7；混合模式；Windows 身份验证部署登录）

来源：`sql/stage2` 尚无脚本；本目录证据对应的实验脚本自本目录 `scripts/` 提供（均已脱敏）。

## 结果摘要

| 实验 | 结论 |
| --- | --- |
| 包含数据库用户路径 | 机制全在线可用（`SET CONTAINMENT = PARTIAL`、口令用户、`EXECUTE AS`）；**登录门在实例认证模式**（仅 Windows 认证时被拒，错误日志"服务器配置为仅使用集成身份验证"）；混合模式下直连成功 |
| 签名与迁移事务 | `ALTER PROCEDURE` 立即丢弃签名（1→0）；`ROLLBACK` 完整还原定义与签名、**无"结构已回滚、签名残留"混合态**；提交路径签名保留 |

## 边界与说明

- 两条登录/认证观察仅代表**本机环境**，不推断其他环境；实例认证模式变更须操作者单独授权并记录回退（回退 = `LoginMode=1` + 重启）。
- 签名实验判据为"对象定义文本 + `sys.crypt_properties` 计数"；低权限执行侧的三路径验收按计划 §5.1 在 2.2 另做（见 `open-issues.md`）。
- 归档脚本中的口令一律以 `<operator-supplied-password>` 代替；日志中命令行同法脱敏（`<示位口令>`）。

## 证据文件

- `stage2-exp-contained-auth-2026-10-13.txt`：包含用户实验的命令、完整输出与退出码（6 步，含终态核对）。
- `stage2-exp-signature-rollback-2026-10-13.txt`：签名实验六阶段输出与退出码。
- `scripts/exp_contained_auth_setup.sql` / `exp_contained_auth_cleanup.sql` / `exp_sig_rollback.sql`：实验脚本（脱敏版）。
- `scripts/elevate_login_mode.cmd`：实例认证模式变更的提权脚本（2026-10-10，经操作者明确授权执行）。
- （2026-10-15 增补）`c-normalization-check-2026-10-15.txt`：`docs/stage2/c-normalization.md` §7 的对账日志（R1 首轮 4 项差异 → 修正 → R4 终轮 0 差异；含脚本两处判据缺陷的处置记录）。
- （2026-10-15 增补）`scripts/check_c_norm.py`：对账脚本（文档 §2 属性与键清单 ↔ `sql/stage1/03` / `06` / `09c` / ER 子图；Python 3.13，`python -I` 运行，可从任意工作目录复跑）。
- （2026-10-17 增补）`er-review-2026-10-17.txt`：A/C 两张 ER 子图的 C 侧独立复核日志（R2 首轮 12 项差异的归因 → 3 处解析器修正 → R3 终轮 0 项问题；A 图 16/16 边通过）。
- （2026-10-17 增补）`scripts/review_er_20261017.py`：复核脚本（实体 / 键 / 边 / 箭头 vs 据 `sql/stage1/01-03` 推导的期望；Python 3.13，`python -I` 运行）。

- （2026-10-27 增补）`stage2-model-check-2026-10-27.txt`：合并总图 `docs/er/stage2-model.drawio/.svg` 的结构/几何对账（H20 三段式：生成过程 5 项缺陷归因 → 修正 → 终轮 103 PASS；含 `naming.md` N-01 的源码反例与 OI-12 依据）。
- （2026-10-27 增补）`scripts/gen_stage2_model.py`：总图生成器（从 `sql/stage1/01–03` + `03`/`05` 唯一约束同源生成 drawio 与 svg；手工版面、显式正交路由、标签自动避让）。
- （2026-10-27 增补）`scripts/check_stage2_model.py`：总图校验器（25 实体/35 外键 ↔ 源码、BR-01–BR-35 ↔ `business-rule-mapping.md`、SVG 线段采样 0 穿盒、35 标签 0 压框/0 互叠、字节；Python 3.13，`python -I` 可从本目录复跑）。
- （2026-10-27 增补）`b-er-review-2026-10-27.txt`：B 域 ER 子图独立复核（10 判据 0 失败；53 列/10 边/箭头/BR 编号全对账，1 条 pickup_code 过滤唯一 note）。
- （2026-10-27 增补）`scripts/review_b_er_20261027.py`：B 子图复核脚本（只读，不改 B 文件）。
- （2026-10-27 增补）`c-contract-auth-check-2026-10-27.txt`：`application-contract.md` §2 的 C 侧授权核对（8 过程守卫/GRANT/白名单/种子/错误码 + 视图边界 + 查询提案未实现；55 PASS；含 52502 分段补注建议）。
- （2026-10-27 增补）`scripts/check_contract_auth_20261027.py`：契约授权核对脚本（只读 A/B 文件）。

- （2026-10-27 增补）`c-er-oi09-followup-2026-10-27.txt`：C 子图 r6 按 OI-09 冻结口径（结构基数）重生成的几何/字节证据（12 实体 / 14 联系、0 穿盒、r6 = `ERzeroToMany`）。
- （2026-10-27 增补）`scripts/gen_c_er.py` / `check_c_er_collide.py`：C 子图生成器与几何自查脚本（可从本目录复跑）。

- （2026-10-30 增补）`c-baseline-protocol-check-2026-10-30.txt`：2.2 基线采集框架的 H20 三段式证据（首轮 7 项实现差异归因 → 修正 → 终轮 31 PASS / 0 FAIL；含失败回滚、重试、VOID、v1.0/停写/漂移守卫）。
- （2026-10-30 增补）`scripts/gen_baseline_sql.py`：按 v0.1 源码生成 `baseline_c.sql` 与仓库外 A/B 测试桩；`scripts/check_baseline_protocol_20261030.sql`：批次状态/元数据/快照行数/摘要/13a offset 的最终验证脚本。
- （2026-10-30 增补）`../../docs/stage2/migration-guide.md`、`../../sql/stage2/capture_baseline.sql`、`../../sql/stage2/baseline_c.sql`：2.2 辅助表/快照形状与采集入口（仓库文件，SHA 见下）。

- （2026-10-31 增补）`c-baseline-b-integration-2026-10-31.txt`：B 的 `baseline_b.sql` 静态核对（46 PASS）与真实集成证据（B 真文件 + C 真文件 + A 临时桩；batch1/2、25 表/178 行、B 五表 53 列逐值双向相等、public DENY 229；17 PASS / 0 FAIL）。
- （2026-10-31 增补）`scripts/check_b_baseline_sql.py`：B 基线文件的 5 表/53 列/键/无事务静态核对；`scripts/check_b_baseline_integration_20261031.sql`：真实集成后的逐值/权限/行数验证。

- （2026-10-31 增补）`c-11c-migration-check-2026-10-31.txt`：11c（Permission 拆分、白名单 46→53、RolePermission 52→66、UQ PurchaseOrder、身份上下文过程）的外层事务回滚/提交实测；旧 52 行与名称保真、签名不变、上下文 51004/正例三结果集。
- （2026-10-31 增补）`scripts/check_11c_rollback_20261031.sql` / `check_11c_commit_20261031.sql`：11c 回滚还原与提交终态/上下文验证脚本。
- （2026-11-03 增补）`c-real-capture-2026-11-03.txt`：真实 A/B/C `baseline_*` 文件的 25 表采集（batch 1 COMPLETED、178 行、摘要）与逐表逐值双向校验（25 PASS / 0 FAIL；H20 三段式，首轮即无差异）。
- （2026-11-03 增补）`scripts/check_capture_real_20261103.sql`：真实采集后的 25 表快照 ↔ 业务表双向 `EXCEPT` 校验脚本。
- （2026-11-03 增补）`c-11c-extension-2026-11-03.txt`：A 的 `11a` 四接口补入 `11c` 后的 57 码/70 行回滚（18/0）、部分迁移提交（57/70、六 UQ）、A `13a`（10/0）与 B `13b`（baseline 5/0、write 8/8）证据；H20 三段式含三个首轮差异归因。
- （2026-11-03 增补）`scripts/check_11c_extension_rollback_20261103.sql`：11a→11c 外层事务回滚夹具；`scripts/check_11a_11c_commit_20261103.sql`：部分迁移提交与 v1.0 标记夹具。
- （2026-11-03 增补）`c-12-13c-runmigration-2026-11-03.txt`：`12_permissions`（缺 11b 时 53404 门禁、临时桩下授权/签名）、`13c`（14/0）、`regression`（37/0）与 `run_migration`（缺 11b 全回滚、临时 11b 桩提交）证据；明确为部分迁移，不含 B 真实 11b/顾客过程。
- （2026-11-03 增补）`scripts/check_12_stubs_20261103.sql`：12/13c 测试用的临时 B/顾客过程桩（只证明脚本机制，不证明 11b 或 OI-10 已交付）。
- （2026-11-03 增补）`c-signature-three-paths-2026-11-03.txt`：真实 v0.1 上三路径签名验收（ALTER 后失败/回滚恢复、重签后成功/回滚恢复、重签提交 + 普通岗位 229；3/0），及未签名调用 50000 + 元数据可见性归因。
- （2026-11-03 增补）`scripts/check_signature_three_paths_20261103.sql`：签名三路径低权限验收脚本。
- （2026-11-03 增补）`c-auth-2026-11-03.txt`：2.3 C 侧 `app/auth`/`run.py` 的 9/0 单测与 master 36/0、orders 18/0 回归；含首轮 test_09 夹具归因与 OI-14 多结果集边界。
- （2026-11-03 增补）`c-inventory-app-2026-11-03.txt`：2.3 C 侧 `app/inventory` 三层（库存/流水/补货/收货）10/0 单测、`run-all.ps1` 四套汇总与部署模板解析；含首轮测试夹具归因、真实 DB/员工角色页边界。
- （2026-11-04 增补）`c-common-oi14-2026-11-04.txt`：A Common 多结果集修复后的 C 侧集成（auth 改 `query_procedure_sets`、身份失效清会话、run-all 五套 13/10/36/18/10）；OI-14 关闭、OI-16 登记。
- （2026-11-05 增补）`c-11c-employee-roles-2026-11-05.txt`：OI-15 的 11c 58/71、`sp_list_employee_roles` 与员工角色页；11c 回滚 9/0、桩迁移提交、13c 15/0、regression 38/0，员工角色页店长正例/普通岗位 229。
- （2026-11-06 增补）`c-oi16-recheck-2026-11-06.txt`：A 的 OI-16 修复后 C 侧复核（common 17/0、auth 10/0、inventory 12/0；本轮不连 SQL Server）。
- （2026-11-06 增补）`c-oi17-runall-2026-11-06.txt`：`run-all.ps1 -Python` 五套 95/0 的完整输出（common 17 / auth 10 / master 36 / orders 20 / inventory 12；`RESULT: run-all files=5 failed=0`）。
- （2026-11-07 增补）`c-53513-rehearsal-2026-11-07.txt`：`run_migration.sql` 53513 从 12 扩到 15 个过程后的迁移预演；A 真实 11a（含 register）+ C 真实 11c/12 + 仓库外 B 临时桩，15 过程/3 个 `cust_app` GRANT/`13c` 15/0；明确不是 B 真实 11b 验收。
- （2026-11-07 增补）`c-runall-2026-11-07.txt`：A 新增 `530xx` 测试后 common 18/0，`run-all.ps1 -Python` 五套 96/0 的完整输出（common 18 / auth 10 / master 36 / orders 20 / inventory 12）。
- （2026-11-09 增补）`c-real-migration-2026-11-09.txt`：B 真实 `11b` 到达后的完整 `run_migration`（无临时桩）：15 个过程/3 个 `cust_app` GRANT/58 码/71 行、`regression` 38/0、六套应用 106/0。
- （2026-11-09 增补）`c-runall-customer-2026-11-09.txt`：`run-all.ps1 -Python` 六套完整输出（common 18 / auth 10 / master 36 / orders 20 / inventory 12 / customer 10；`RESULT: run-all files=6 failed=0`）。
- （2026-11-09 增补）`c-inventory-security-2026-11-09.txt`：`tests/stage2/inventory-security` 入口调用真实 v1.0 的 13c，`RESULT: pass=15 fail=0`、`RESULT: inventory-security files=1 pass=15 fail=0`。
- （2026-11-09 增补）`c-http-integration-2026-11-09.txt`：C 技术联调 smoke；用随机临时 SQL 登录（不打印口令、跑完 drop）走 store/master/inventory/orders、五个 B 岗位订单页、shift 库存页，以及顾客建档→下单→取餐码查单；`RESULT: pass=3 fail=0 total=3`。
- （2026-11-09 增补）`c-inventory-customer-ui/README.md` + 7 张 PNG：真实 v1.0 下的员工登录/店长身份/库存看板/员工角色/顾客三表单/下单结果/查单截图；临时 SQL 登录随机口令，截图后恢复用户并删除登录。
- （2026-11-09 增补）`c-customer-custapp-2026-11-09.txt`：`EXECUTE AS USER='cust_app'` 实调 register/place/list 三过程（3/0，事务回滚）；不是真实 HTTP 顾客登录。

## SHA-256

```text
23B9CE1059206369DFBA238EE5657C88E4F19F3E8082533C2D40E14D45C03BA4  stage2-exp-contained-auth-2026-10-13.txt
007944779290B305C3C994A5B29E5144E3417FA9595B210008B0720F19EA1BE9  stage2-exp-signature-rollback-2026-10-13.txt
7F98A031CDEB39A3934BFC427637CBF13F114D1CDBE1D885F8AD926C4845A8E8  scripts/exp_contained_auth_setup.sql
9B063D826B3EFC03B599C6B8F9714E8616013C826ACD82C1B9EE9E989706A21F  scripts/exp_contained_auth_cleanup.sql
94D864BF7B037A56B8450B5A346D16C7485285B0BADDE5716985066AD60C431E  scripts/exp_sig_rollback.sql
B6C3A419164B39EC201998EB2BA732B2AF28EBC6BA628790A5CAD61C43E51299  scripts/elevate_login_mode.cmd
D8933489870A076F7FBBBF5F684B9138F7687058CA55D2208DEFE42C931B8579  c-normalization-check-2026-10-15.txt
4695DB886C7373E881B7EB5DF6DD821147156BE93A1ED6FC7D95278B570B9031  scripts/check_c_norm.py
142D7F016282485BA2CC41B30F5C7406ECD8CD6A09717697B556F0C9B8B44FEB  er-review-2026-10-17.txt
31A09A4BE418AF19B7182CB11EC0846EA9A0D6E25AC08FE8886F4B98FAE327B3  scripts/review_er_20261017.py
7F4BB0049E9E05A84F0BB313616E9F3831EEE335AC32E4437FB4B78A3219CF9E  stage2-model-check-2026-10-27.txt
7AC703172CAA763E691BA672F9FE76C8D82C18006F19DCCD7C734385E16A47F8  b-er-review-2026-10-27.txt
ED766C58F5FCF53E60C2399B4E50E00FC858AC4F38CE71EC57556965810CA4B1  c-contract-auth-check-2026-10-27.txt
FD0ABF69C42A324AD3AF17988046DF2C259DE6889B72AE4282C13DDD439E8829  scripts/gen_stage2_model.py
243F828B5CCB7FE0246D9E9422AB3E41C2F57FCB6FB0C4AC6CB5C45E05536845  scripts/check_stage2_model.py
5CB0B9DB14C457CD12D5051853E35BC90A4CBA8F088E6AA4E9545AB43245D2FE  scripts/review_b_er_20261027.py
0F83A08434E90F3519CB884615CC76BFF9104761701322F426A24BCB82C7E3A8  c-baseline-b-integration-2026-10-31.txt
9447B88168F6EF8BE69FB4D0F06AD5F91F85248C973D6CDF024A2D81C4737260  scripts/check_b_baseline_sql.py
EE294A2EB436E80CB60A9E29BC9D48761FEC8A9C5667165E1102700C820F04C2  scripts/check_b_baseline_integration_20261031.sql
435920CBB1DB5E9B9CEA72F88E0DF732A2BEBBA6C62C5F44AE915729A157617E  c-11c-migration-check-2026-10-31.txt
5F7EA94ACF81F604EF107275ADCB30A7C127694C211C739A94C3E5E56B94C79D  scripts/check_11c_rollback_20261031.sql
2CE42E19BF31C74456ACDA3689E9079C1E052E04856917C28367F27E6D062A9A  scripts/check_11c_commit_20261031.sql
B63C349044115A63E0458E3539F731C8D05FBDFF239EF2F64A63B14CD0B1B18C  scripts/check_contract_auth_20261027.py
9052EE18A2225235DEDD8974A4B83718E0D16B86A29F79347E812BB1ABCB3F74  c-baseline-protocol-check-2026-10-30.txt
166A263A899E423FD0843D0DA4B90EC33863B59A2EA6F98065F2EB58394B4488  scripts/gen_baseline_sql.py
89D082103F9BCA658E2DF24BCD75E6B39D04719E7885E69A855612816601462F  scripts/check_baseline_protocol_20261030.sql
C74A2BE06C7B5C49D4667EFF6B0D2FF0E229069196A2A21482732D38ED4EDD7C  c-er-oi09-followup-2026-10-27.txt
3B8CF7CBD6DB7E9A748A6CFC37DF9716713AAC362443BDA935431E8D9E6E044E  scripts/gen_c_er.py
71D4946CFE2151946FE828F36C5B9D0ECF0B3A33EE59DE88626D2C25F5B6DCF6  scripts/check_c_er_collide.py
FCE7DF547BDC6BF98C8328BDC2A2F95B2B59A75BA00543AEE63C8CF44945BD07  c-real-capture-2026-11-03.txt
57FB7919918DECC100BBA3D4CBE404BB5CDB62946E18725E89D58A3045F34F19  scripts/check_capture_real_20261103.sql
B8AF6861786260BCFE820203A8EA4626CF72FB49AB6D226A3D4DB9C08A460163  c-11c-extension-2026-11-03.txt
A09E0E9E15C6E82FF04F32295FB703291A71A8E30F108601D1EE0659EFB7CA13  scripts/check_11c_extension_rollback_20261103.sql
35F484FCCBD5AD33D9164EFA8954E7087ED8D31109F9D503164BF7D98F244CA6  scripts/check_11a_11c_commit_20261103.sql
D0A6C3327D0CFED5A94FB9A3A3F57AEAF51AF9B653AC99905E8D5E6759DAAF20  c-12-13c-runmigration-2026-11-03.txt
E00AAB5340DA954E3B21D478D30D7E1525C98DFFDCFBC64F8C20AD28C2C83D2B  scripts/check_12_stubs_20261103.sql
FAE1A1AA9B5C57E106076C02B5FA5DD5A3CB34C1A82DD5B9EFFCD111454144F7  c-signature-three-paths-2026-11-03.txt
62ECD20C7FB8A1CE7FDF97A20884BEDF480F4D8D6AFE3C0DBDD972C3FF67A27E  scripts/check_signature_three_paths_20261103.sql
442DC5DD8AA540B78CAC744AE8B99AAEDE9FB3E3CADB3363195FF13670223B0B  c-auth-2026-11-03.txt
F9CFACE4F3A2011FA7433467B484C13651F0D68A3E3E2C6958BEFF550F9D18E6  c-inventory-app-2026-11-03.txt
3AB44BC0E3E4B4953AA225E67999F1CD16FB7CC3225A227E193476DA15DA0A2D  c-common-oi14-2026-11-04.txt
1E51AA780B933F8133EA78A5198328B170676320CBDAE492E5E978D80CB58EDF  scripts/check_11c_employee_roles_20261105.sql
6B35BEE0746B6FEC0642B67DB74C9D13BF38F657D43F4D2EF25CAFF4DE274772  c-11c-employee-roles-2026-11-05.txt
3A4191E1F9FE280EDB6AF2F241C8BE982F3C33B985D914BC4EC45946B8279582  ../../sql/stage2/11c_inventory_security_migration.sql
790AAF8F3021CDD77E1E487886F666F054DC6A87E5C7E3BEDE55665A6F276FEF  ../../sql/stage2/12_permissions.sql
86F23E944E0AD0FF3ED22A7358FDFDA00E410D6FF6DEA675BC87E9F315A8C42B  ../../sql/stage2/13c_inventory_security_regression.sql
E7D3FD93231B680071BABF1620ED8B10F1DE647BD148D3890C659F14780043D1  ../../sql/stage2/run_migration.sql
9CD4AE2C94D74BB63360E14FCAAE86315160946D34787F8D66D29F75B2E4B3A4  ../../sql/stage2/regression.sql
C45DDF378F7D57098E19586FFD35B9D8FD9FD9CBA41C24E5283EC5A18CE663F8  c-oi16-recheck-2026-11-06.txt
1E3D1A0AD952F470BE714243EA8276ED5F295E547170D9B1E92AC4451C2A0B71  c-oi17-runall-2026-11-06.txt
A7C8AAC339A4072BD04CA02A699280EFCCA6F73C37E8507AD31119691788999F  c-53513-rehearsal-2026-11-07.txt
D0436C45472FB30BF6912FBBA400BDA911C1DDF23C5CECE56D7F69DC5337C659  c-runall-2026-11-07.txt
D803E7D78DAD7522F587D1DD3DDCA9FD5414A137274E98F4A91918657752D09E  c-real-migration-2026-11-09.txt
45103A244F8D883221D4F8F9356F492B9B2DB6C9BC0B6C468B58DB57131F017C  c-runall-customer-2026-11-09.txt
775A854598F3F76FBDB78A8C5A417DDC27CBAE41338213B7359B7DB8ECC45849  c-customer-custapp-2026-11-09.txt
075851AD9483936D67F913B498B5C11AB32D8DB0EB9CFA403E4CFC962A6E6BD1  c-inventory-security-2026-11-09.txt
79760FDB0FEC17914C2044FA9329FD1179279BFAEF4051ED9536121C97F5F6B3  c-http-integration-2026-11-09.txt
```
