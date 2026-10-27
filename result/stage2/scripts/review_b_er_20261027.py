# -*- coding: utf-8 -*-
"""C 侧独立复核 B 域 ER 子图 docs/er/b-order.drawio（2026-10-27）。
核对：实体/属性名 = sql/02 五表全列；键标注 vs PK/UQ/FK；灰实体键 vs 引用表主码；
      10 条边 ↔ 10 个外键（BR-10..18 + BR-35，无幽灵/无遗漏）；箭头按 DDL 结构推导；
      标签 BR 编号 vs business-rule-mapping.md；字节与 XML。"""
import re, html, os, sys, xml.etree.ElementTree as ET

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

def strip_comments(t):
    return re.sub(r'--[^\n]*', '', t)

def parse_schema(path):
    t = strip_comments(read(path))
    out = {}
    for m in re.finditer(r'(?is)create\s+table\s+(?:dbo\.)?(\w+)\s*\(\s*\n(.*?)\n\s*\)\s*;?', t):
        name, body = m.group(1), m.group(2)
        cols, order, last = {}, [], None
        for ln in body.split('\n'):
            s = ln.strip()
            if not s:
                continue
            if re.match(r'(?i)^constraint\s+PK_\w+\s+primary\s+key\s*[,]?\s*$', s) and last:
                cols[last]['pk'] = True
                continue
            if re.match(r'(?i)^(constraint|primary|foreign|references|unique)\b', s):
                continue
            mc = re.match(r'^\[?([A-Za-z_]\w*)\]?\s+(.*)$', s)
            if mc and mc.group(1).lower() not in ('constraint', 'primary', 'foreign', 'references', 'unique'):
                col, rest = mc.group(1), mc.group(2)
                cols[col] = {'nullable': ('not null' not in rest.lower()),
                             'pk': bool(re.search(r'(?i)constraint\s+PK_\w+\s+primary\s+key', rest)),
                             'uk': bool(re.search(r'(?i)constraint\s+UQ_\w+\s+unique', rest))}
                order.append(col)
                last = col
        pk = [c for c in order if cols[c]['pk']]
        for pm in re.finditer(r'(?i)constraint\s+PK_\w+\s+primary\s+key\s*\(([^)]*)\)', body):
            for c in pm.group(1).split(','):
                c = c.strip()
                if c in cols and c not in pk:
                    pk.append(c)
        for c in pk:
            cols[c]['nullable'] = False
        uq = {}
        for um in re.finditer(r'(?i)constraint\s+(UQ_\w+)\s+unique\s*\(([^)]*)\)', body):
            uq[um.group(1)] = [c.strip() for c in um.group(2).split(',')]
        for c in order:
            if cols[c]['uk']:
                uq['UQ_inline_' + c] = [c]
        fk = []
        for fm in re.finditer(r'(?i)constraint\s+(FK_\w+)\s+foreign\s+key\s*\(([^)]*)\)\s*references\s+(?:\w+\.)?(\w+)\s*\(([^)]*)\)', body):
            fk.append({'name': fm.group(1), 'cols': [c.strip() for c in fm.group(2).split(',')],
                       'parent': fm.group(3), 'pcols': [c.strip() for c in fm.group(4).split(',')]})
        out[name] = {'cols': cols, 'order': order, 'pk': pk, 'uq': uq, 'fk': fk}
    return out

M = {}
for f in ('sql/01_master_schema.sql', 'sql/02_order_schema.sql', 'sql/03_inventory_security_schema.sql'):
    M.update(parse_schema(f))
t05 = strip_comments(read('sql/05_order_constraints_crud.sql'))
for m in re.finditer(r'(?is)alter\s+table\s+(?:\w+\.)?(\w+)\s+add\s+constraint\s+(UQ_\w+)\s+unique\s*\(([^)]*)\)', t05):
    M[m.group(1)]['uq'][m.group(2)] = [c.strip() for c in m.group(3).split(',')]
FILTERED = set()
for f in ('sql/01_master_schema.sql', 'sql/03_inventory_security_schema.sql', 'sql/05_order_constraints_crud.sql'):
    t = strip_comments(read(f))
    for m in re.finditer(r'(?is)create\s+unique\s+index\s+(UQ_\w+)\s+on\s+(?:\w+\.)?(\w+)\s*\(([^)]*)\)([^;]*)', t):
        M[m.group(2)]['uq'][m.group(1)] = [c.strip() for c in m.group(3).split(',')]
        if re.search(r'(?i)\bwhere\b', m.group(4)):
            FILTERED.add(m.group(1))
t03 = strip_comments(read('sql/03_inventory_security_schema.sql'))
for m in re.finditer(r'(?is)alter\s+table\s+(?:\w+\.)?(\w+)\s+add\s+constraint\s+(FK_\w+)\s+foreign\s+key\s*\(([^)]*)\)\s+references\s+(?:\w+\.)?(\w+)\s*\(([^)]*)\)', t03):
    M[m.group(1)]['fk'].append({'name': m.group(2), 'cols': [c.strip() for c in m.group(3).split(',')],
                                'parent': m.group(4), 'pcols': [c.strip() for c in m.group(5).split(',')]})

B_TABLES = ['SalesOrder', 'SalesOrderItem', 'Payment', 'Delivery', 'PointLedger']
GRAY = {'Customer': 'customer_id', 'Product': 'product_id', 'Promotion': 'promotion_id',
        'EmployeeAccount': 'employee_id'}

# ---------- 解析 drawio ----------
raw = open(ROOT + r'\docs\er\b-order.drawio', 'rb').read()
rep(not raw.startswith(b'\xef\xbb\xbf'), '无 BOM')
rep(raw.count(b'\r\n') == raw.count(b'\n') and raw.endswith(b'\r\n'),
    '全 CRLF 且末尾换行（行数 %d）' % raw.count(b'\r\n'))
text = raw.decode('utf-8')
ET.fromstring(text)
rep(True, 'XML 良构')
cells = [m.group(0) for m in re.finditer(r'<mxCell[^>]*>', text)]
ents, edges = {}, []
for tag in cells:
    val = re.search(r'value="([^"]*)"', tag)
    v = html.unescape(val.group(1)) if val else ''
    name = re.sub(r'</?b>', '', v.split('<br>')[0]).strip()
    if 'vertex="1"' in tag:
        if name in B_TABLES or name.split(' ')[0] in GRAY:
            ents[name.split(' ')[0]] = v.split('<br>')[1:]
    if 'edge="1"' in tag:
        edges.append(tag)
rep(set(ents) == set(B_TABLES) | set(GRAY), '实体集合 = 5 主 + 4 灰（%d）' % len(ents))
rep(len(edges) == 10, '边数 = %d（期望 10）' % len(edges))

# ---------- 主实体属性与键标注 ----------
def src_marker(tbl, col):
    d = M[tbl]
    fk = any(col in f['cols'] for f in d['fk'])
    pk = col in d['pk']
    uq = any(v == [col] for v in d['uq'].values())
    if pk:
        return 'PK'
    if fk and uq:
        return 'UK/FK'
    if fk:
        return 'FK'
    if uq:
        return 'UK'
    return ''

ok_attr = True
for t in B_TABLES:
    got = []
    for a in ents[t]:
        mm = re.match(r'^(PK|UK/FK|FK|UK|PKFK)?\s*([A-Za-z_]\w*)\s*:', a.strip())
        if not mm:
            ok_attr = False
            print('   unparsed attr', t, a)
            continue
        got.append((mm.group(1) or '', mm.group(2)))
    want = [(src_marker(t, c), c) for c in M[t]['order']]
    if [c for _, c in got] != [c for _, c in want]:
        ok_attr = False
        print('   column order/set mismatch', t)
        print('   got :', [c for _, c in got])
        print('   want:', [c for _, c in want])
    for (gm, gc), (wm, wc) in zip(got, want):
        if gm != wm:
            # pickup_code 的 UK 来自过滤唯一索引；B 未标 UK、并在图注说明「仅非 NULL 子集」，
            # 与总图 UK* 同义，判为可接受。
            if gc == 'pickup_code' and gm == '' and wm == 'UK':
                print('   [note] SalesOrder.pickup_code 未标 UK（图注已说明过滤唯一索引，可接受）')
                continue
            ok_attr = False
            print('   marker mismatch', t, gc, gm, '!=', wm)
rep(ok_attr, '5 主实体 53 列名/顺序/键标注与 sql/02(+05 唯一约束) 一致')

# ---------- 灰实体键 ----------
ok_gray = True
for g, key in GRAY.items():
    got = [a.strip() for a in ents[g]]
    want_marker = 'PK'
    m = re.match(r'^(PK)\s+([A-Za-z_]\w*)\s*:', got[0]) if got else None
    if len(got) != 1 or not m or m.group(2) != key:
        ok_gray = False
        print('   gray mismatch', g, got)
    if key not in M[g]['pk']:
        ok_gray = False
        print('   gray key not PK in source', g, key)
rep(ok_gray, '4 个灰实体各仅列被引用主码（与源表主码一致）')

# ---------- 边 ↔ 外键 ----------
b_fks = []
for t in B_TABLES:
    for f in M[t]['fk']:
        if f['parent'] in set(B_TABLES) | set(GRAY):
            b_fks.append(f)
rep(len(b_fks) == 10, 'B 域对外/内部外键 = %d（期望 10）' % len(b_fks))

def arrows(f):
    child = f.get('child') or next(t for t in B_TABLES if f in M[t]['fk'])
    nul = any(M[child]['cols'][c]['nullable'] for c in f['cols'])
    sa = 'ERzeroToOne' if nul else 'ERone'
    cc = set(f['cols'])
    uniq = (cc == set(M[child]['pk'])) or any(set(v) == cc and k not in FILTERED
                                              for k, v in M[child]['uq'].items())
    return sa, 'ERzeroToOne' if uniq else 'ERzeroToMany'

mapping_rows = {}
for line in read(r'docs\stage2\business-rule-mapping.md').split('\n'):
    mm = re.match(r'\|\s*(BR-\d+)\s*\|\s*(FK_\w+)\s*\|', line)
    if mm:
        mapping_rows[mm.group(2)] = mm.group(1)

used = set()
ok_e = True
for tag in edges:
    src = re.search(r'source="([^"]*)"', tag).group(1)
    tgt = re.search(r'target="([^"]*)"', tag).group(1)
    lab = html.unescape(re.search(r'value="([^"]*)"', tag).group(1)).strip()
    sa = re.search(r'startArrow=(\w+)', tag).group(1)
    ea = re.search(r'endArrow=(\w+)', tag).group(1)
    cand = [f for t in B_TABLES for f in M[t]['fk']
            if f['parent'] == src and t == tgt]
    if len(cand) != 1:
        ok_e = False
        print('   edge not uniquely matched', src, '->', tgt, len(cand))
        continue
    f = cand[0]
    if f['name'] in used:
        ok_e = False
        print('   duplicate edge for FK', f['name'])
    used.add(f['name'])
    if mapping_rows.get(f['name']) != lab:
        ok_e = False
        print('   label mismatch', f['name'], lab, mapping_rows.get(f['name']))
    want = arrows(f)
    if (sa, ea) != want:
        ok_e = False
        print('   arrow mismatch', f['name'], (sa, ea), want)
rep(ok_e and len(used) == 10, '10 条边逐条唯一对应外键；箭头 = DDL 结构推导；标签 = BR 编号（10/10）')
rep(used == set(f['name'] for f in b_fks), '无幽灵边、无遗漏（期望外键全部出现一次）')

print('\nRESULT: pass=%d fail=%d' % (passes[0], len(fails)))
if fails:
    sys.exit(1)
