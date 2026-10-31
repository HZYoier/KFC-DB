# -*- coding: utf-8 -*-
"""C 侧静态核对 B 的 baseline_b.sql（2026-10-31）：
5 表/53 列与 sql/02 逐列一致；batch_id + 原主键；无 IDENTITY/DEFAULT/FK/业务 CHECK；
无 GO / 事务 / USE；INSERT 显式列 = 全列；@batch_id；public DENY。"""
import re, os

ROOT = r'D:\DBLab\KFC-DB'
fails, passes = [], [0]
def rep(ok, msg):
    print(('[PASS] ' if ok else '[FAIL] ') + msg)
    if ok: passes[0] += 1
    else: fails.append(msg)

def read(p):
    return open(os.path.join(ROOT, p), encoding='utf-8').read()

def strip_comments(t):
    return re.sub(r'--[^\n]*', '', t)

TYPE_RE = re.compile(r'(?i)^(BIGINT|INT|SMALLINT|TINYINT|BIT|DECIMAL\s*\(\s*\d+\s*,\s*\d+\s*\)|NUMERIC\s*\(\s*\d+\s*,\s*\d+\s*\)|VARCHAR\s*\(\s*\d+\s*\)|NVARCHAR\s*\(\s*(?:\d+|MAX)\s*\)|CHAR\s*\(\s*\d+\s*\)|DATETIME2\s*\(\s*\d+\s*\)|DATETIME|DATE|TIME\s*\(\s*\d+\s*\))')

def norm(s):
    s = re.sub(r'\s+', '', s).upper()
    return s

# sql/02 source
t = strip_comments(read('sql/02_order_schema.sql'))
src = {}
for m in re.finditer(r'(?is)create\s+table\s+(?:dbo\.)?(\w+)\s*\(\s*\n(.*?)\n\s*\)\s*;?', t):
    name, body = m.group(1), m.group(2)
    cols, order, last = {}, [], None
    for ln in body.split('\n'):
        s = ln.strip()
        if not s: continue
        if re.match(r'(?i)^constraint\s+PK_\w+\s+primary\s+key', s) and last:
            cols[last]['pk'] = True; continue
        if re.match(r'(?i)^(constraint|primary|foreign|references|unique)\b', s):
            continue
        mc = re.match(r'^\[?([A-Za-z_]\w*)\]?\s+(.*)$', s)
        if not mc: continue
        tm = TYPE_RE.match(mc.group(2))
        if not tm: continue
        cols[mc.group(1)] = {'type': norm(tm.group(1)), 'nullable': ('not null' not in mc.group(2).lower()),
                             'pk': bool(re.search(r'(?i)constraint\s+PK_\w+\s+primary\s+key', mc.group(2)))}
        order.append(mc.group(1)); last = mc.group(1)
    pk = [c for c in order if cols[c]['pk']]
    for pm in re.finditer(r'(?i)constraint\s+PK_\w+\s+primary\s+key\s*\(([^)]*)\)', body):
        for c in pm.group(1).split(','):
            c = c.strip()
            if c in cols and c not in pk: pk.append(c)
    for c in pk: cols[c]['nullable'] = False
    src[name] = {'cols': cols, 'order': order, 'pk': pk}

B_TABLES = ['SalesOrder', 'SalesOrderItem', 'Payment', 'Delivery', 'PointLedger']
raw = read('sql/stage2/baseline_b.sql')
bt = strip_comments(raw)
rep(len([l for l in raw.split('\n') if l.strip().upper() == 'GO']) == 0, 'baseline_b 无 GO')
rep(not re.search(r'(?i)\b(BEGIN|COMMIT|ROLLBACK)\s+TRAN', bt), 'baseline_b 无事务控制')
rep(not re.search(r'(?i)^\s*USE\s+', bt, re.M), 'baseline_b 无 USE')
rep(len(re.findall(r'@batch_id', bt)) >= 5, 'baseline_b 使用入口 @batch_id')

for tbl in B_TABLES:
    m = re.search(r'(?is)create\s+table\s+dbo\.Baseline_%s\s*\((.*?)\)\s*;' % tbl, bt)
    rep(m is not None, '%s 快照表已定义' % tbl)
    if not m: continue
    body = m.group(1)
    cols, order, last = {}, [], None
    for ln in body.split('\n'):
        s = ln.strip().rstrip(',')
        if not s: continue
        if s.upper().startswith('CONSTRAINT'):
            continue
        mc = re.match(r'^\[?([A-Za-z_]\w*)\]?\s+(.*)$', s)
        if not mc: continue
        tm = TYPE_RE.match(mc.group(2))
        if not tm: continue
        col = mc.group(1)
        cols[col] = {'type': norm(tm.group(1)), 'nullable': ('not null' not in mc.group(2).lower())}
        order.append(col)
    want = ['batch_id'] + src[tbl]['order']
    rep(order == want, '%s 列序 = batch_id + 源 53/53 列（实际 %d）' % (tbl, len(order)))
    rep(cols.get('batch_id', {}).get('type') == 'BIGINT' and cols['batch_id']['nullable'] is False,
        '%s batch_id BIGINT NOT NULL' % tbl)
    ok = all(cols[c]['type'] == src[tbl]['cols'][c]['type'] and cols[c]['nullable'] == src[tbl]['cols'][c]['nullable']
             for c in src[tbl]['order'])
    rep(ok, '%s 全部类型/可空性一致' % tbl)
    pm = re.search(r'PRIMARY\s+KEY\s*\(([^)]*)\)', body, re.I)
    pkcols = [c.strip(' []') for c in pm.group(1).split(',')] if pm else []
    rep(pkcols == ['batch_id'] + src[tbl]['pk'], '%s 主键 = (batch_id, 源主键)' % tbl)
    rep(not re.search(r'(?i)\bIDENTITY\b|\bDEFAULT\b|FOREIGN\s+KEY|REFERENCES', body),
        '%s 无 IDENTITY/DEFAULT/FK' % tbl)
    im = re.search(r'(?is)INSERT\s+INTO\s+dbo\.Baseline_%s\s*\(([^)]*)\)\s*SELECT\s+@batch_id,\s*(.*?)\s+FROM\s+dbo\.%s\s*;' % (tbl, tbl), bt)
    rep(im is not None, '%s INSERT 形状正确' % tbl)
    if im:
        ins = [c.strip(' []') for c in im.group(1).split(',')]
        sel = [c.strip(' []') for c in im.group(2).split(',')]
        rep(ins == want and sel == src[tbl]['order'], '%s INSERT/SELECT 列清单 = 全列' % tbl)

rep(len(re.findall(r'(?i)DENY\s+SELECT,\s*INSERT,\s*UPDATE,\s*DELETE\s+ON\s+OBJECT::dbo\.Baseline_', bt)) == 5,
    '5 个快照表均有 public DENY')
rep('permission_name' not in bt and 'Customer' not in bt and 'Inventory' not in bt,
    'B 文件不越界写 A/C 表（仅 B 五表）')

print('\nRESULT: pass=%d fail=%d' % (passes[0], len(fails)))
if fails:
    raise SystemExit(1)
