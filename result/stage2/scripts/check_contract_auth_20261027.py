# -*- coding: utf-8 -*-
"""C 侧并行核对 application-contract.md §2.1 的岗位授权（2026-10-27）。
核对：8 个写过程的岗位守卫（含 ACTIVE）、08 GRANT 与守卫一一对应、06 白名单、
      09c RolePermission 种子、52xxx 错误码分段、§2.2 视图授权边界、6 个查询提案未实现。
只读 A/B 文件，不修改。"""
import re, os, sys

ROOT = r'D:\DBLab\KFC-DB'
fails, passes = [], [0]
def rep(ok, msg):
    print(('[PASS] ' if ok else '[FAIL] ') + msg)
    if ok:
        passes[0] += 1
    else:
        fails.append(msg)

def read(p):
    return open(os.path.join(ROOT, p), encoding='utf-8').read()

t05 = read('sql/05_order_constraints_crud.sql')
t06 = read('sql/06_inventory_constraints_crud.sql')
t08 = read('sql/08_roles_permissions.sql')
t09c = read('sql/09c_inventory_opening_seed_data.sql')

EXP = {
    'sp_create_order':          ('cashier', 'CASHIER', range(52100, 52115)),
    'sp_pay_order':             ('cashier', 'CASHIER', range(52201, 52207)),
    'sp_start_production':      ('chef', 'CHEF', range(52301, 52302)),
    'sp_finish_production':     ('packer', 'PACKER', range(52401, 52402)),
    'sp_pick_up_order':         ('packer', 'PACKER', range(52501, 52503)),
    'sp_pick_up_delivery':      ('rider', 'RIDER', range(52601, 52604)),
    'sp_confirm_delivery':      ('rider', 'RIDER', range(52701, 52703)),
    'sp_cancel_or_refund_order': ('store_manager', 'STORE_MANAGER', range(52801, 52807)),
}

# ---------- 05 过程体 ----------
blocks = {}
for m in re.finditer(r'(?is)create\s+procedure\s+(?:dbo\.)?(\w+)(.*?)(?=\n\s*GO\b|\Z)', t05):
    blocks[m.group(1)] = m.group(2)
rep(set(blocks) == set(EXP), '05 恰含契约 §2.1 的 8 个写过程（实际 %d）' % len(blocks))

for name, (role, job, seg) in EXP.items():
    body = blocks[name]
    guards = re.findall(r"job_code\s*=\s*'([A-Z_]+)'", body)
    rep(guards and set(guards) == {job},
        '%s 岗位守卫 = %s（实际 %s）' % (name, job, sorted(set(guards))))
    rep(re.search(r"status\s*=\s*'ACTIVE'", body) is not None,
        '%s 守卫含员工 ACTIVE 条件（停用即拒）' % name)
    codes = sorted(set(int(c) for c in re.findall(r'THROW\s+(\d+)', body)))
    allowed = set(seg) | {52100}  # 52100 = B 域统一「岗位不符」（契约 §2.1 明文）
    extra = [c for c in codes if c not in allowed]
    # sp_confirm_delivery 复用 52502（积分终态校验，与取餐路径同义）——契约分段描述未覆盖，记 note
    if name == 'sp_confirm_delivery' and 52502 in extra:
        print('   [note] sp_confirm_delivery 复用 52502（积分终态校验），契约分段表未列，已记复核发现')
        extra.remove(52502)
    rep(not extra and len(codes) > 0,
        '%s 错误码 ⊆ {52100} ∪ %d–%d（实际 %s）' % (name, min(seg), max(seg), codes))

# ---------- 08 GRANT ----------
grants = {}
for m in re.finditer(r'(?i)GRANT\s+EXECUTE\s+ON\s+(?:dbo\.)?(\w+)\s+TO\s+(\w+)', t08):
    grants.setdefault(m.group(1), set()).add(m.group(2))
for name, (role, job, _) in EXP.items():
    got = grants.get(name, set())
    rep(got == {'role_' + role},
        '%s 的 EXECUTE 仅授予 role_%s（实际 %s）' % (name, role, sorted(got)))

# ---------- 06 白名单 ----------
m = re.search(r'(?is)permission_code\s+IN\s*\((.*?)\n\s*\)\s*\)', t06)
wl = re.findall(r"'([a-z_][a-z0-9_]*)'", m.group(1)) if m else []
rep(m is not None and len(wl) == 46, '06 白名单条目 = %d（期望 46）' % len(wl))
for name in EXP:
    rep(name in wl, '白名单含 %s' % name)

# ---------- 09c 种子 ----------
seeds = set(re.findall(r"\('([a-z_]+)',\s*'([a-z_0-9]+)'\s*,", t09c))
for name, (role, job, _) in EXP.items():
    rep((role, name) in seeds, '09c 种子含 (%s, %s)' % (role, name))

# ---------- 视图授权边界（§2.2 权限边界段） ----------
view_grants = {}
for m in re.finditer(r'(?i)GRANT\s+SELECT\s+ON\s+(?:dbo\.)?(\w+)\s+TO\s+(\w+)', t08):
    view_grants.setdefault(m.group(1), set()).add(m.group(2))
rep('role_chef' in view_grants.get('v_kitchen_queue', set()), 'v_kitchen_queue 授予 role_chef')
rep('role_waiter' in view_grants.get('v_pickup_board', set()), 'v_pickup_board 授予 role_waiter')
rep('role_store_manager' in view_grants.get('v_order_detail', set()), 'v_order_detail 授予 role_store_manager')
rep('role_cashier' not in view_grants.get('v_customer_point_ledger', set()),
    'v_customer_point_ledger 未授予 role_cashier（不能作为收银支付页数据源）')

# ---------- 6 个查询提案未实现 ----------
proposals = ['sp_list_orders_for_payment', 'sp_get_order_for_payment', 'sp_get_order_operation_status',
             'sp_list_orders_for_packing', 'sp_list_my_deliveries', 'sp_list_deliveries_available_for_pickup']
all_sql = ''.join(read('sql/' + f) for f in os.listdir(os.path.join(ROOT, 'sql')) if f.endswith('.sql'))
rep(not any(p in all_sql for p in proposals), '6 个查询提案在 sql/ 中均未实现（与契约「尚未实现」一致）')

print('\nRESULT: pass=%d fail=%d' % (passes[0], len(fails)))
if fails:
    sys.exit(1)
