# stage2 证据（C 侧）

隔离实验执行日期：2026-10-13（重跑捕获；实验首做于 2026-10-10，本次为归档要求下的完整复现）；文档对账证据增补于 2026-10-15。

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
- （2026-10-15 增补）`scripts/check_c_norm.py`：对账脚本（文档 §2 属性与键清单 ↔ `sql/03` / `06` / `09c` / ER 子图；Python 3.13，`python -I` 运行，可从任意工作目录复跑）。

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
```
