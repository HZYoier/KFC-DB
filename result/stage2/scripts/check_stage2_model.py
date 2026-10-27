# -*- coding: utf-8 -*-
"""总图验收：结构对账（sql 源码 / business-rule-mapping / drawio）+ 几何避让（SVG 实际线段/标签）+ 字节。
输出 [PASS]/[FAIL] 行与 RESULT 汇总，供 result/stage2 归档（H20）。"""
import re, html, io, contextlib, runpy, os, xml.etree.ElementTree as ET

ROOT = r'D:\DBLab\KFC-DB'
HERE = os.path.dirname(os.path.abspath(__file__))
fails = []
passes = [0]
def rep(ok, msg):
    print(('[PASS] ' if ok else '[FAIL] ') + msg)
    if ok:
        passes[0] += 1
    else:
        fails.append(msg)

# 复用生成器数据（runpy 会重写两个文件，确定性输出）
GEN = os.path.join(HERE, 'gen_stage2_model.py')
if not os.path.exists(GEN):
    GEN = r'D:\DBLab\_kfcdb_tmp\gen_stage2_model.py'
buf = io.StringIO()
with contextlib.redirect_stdout(buf):
    g = runpy.run_path(GEN)
MODEL, POS, EDGES, ALL_FK = g['MODEL'], g['POS'], g['EDGES'], g['ALL_FK']
BOX_W, ent_h, attr_lines = g['BOX_W'], g['ent_h'], g['attr_lines']
FILTERED = g['FILTERED']

def read(p):
    return open(ROOT + p, encoding='utf-8').read()

def readb(p):
    return open(ROOT + p, 'rb').read()

# ---------------- 1. drawio 结构 ----------------
drawio = read(r'\docs\er\stage2-model.drawio')
root = ET.fromstring(drawio)
cells = root.findall('.//mxCell')
ents, edges = {}, {}
for c in cells:
    cid = c.get('id')
    if c.get('vertex') == '1' and cid and cid.startswith('E_'):
        ents[cid[2:]] = html.unescape(c.get('value', ''))
    if c.get('edge') == '1':
        edges[cid] = c
rep(len(ents) == 25, 'drawio 实体数 = %d（期望 25）' % len(ents))
rep(set(ents) == set(MODEL), 'drawio 实体名集合与 sql 源码 25 表一致')
for t in MODEL:
    got = ents[t].split('<br>')[1:]
    want = attr_lines(t)
    rep(got == want, '%s 属性行逐项一致（%d 列）' % (t, len(want)))

rep(len(edges) == 35, 'drawio 边数 = %d（期望 35）' % len(edges))
rep(set(edges) == set(ALL_FK), 'drawio 边 id 集合 = 35 个外键名（逐名去重，无遗漏/无多余）')

# 箭头与结构推导
def arrows_of(e):
    fk = ALL_FK[e['fk']]
    child = fk['child']
    nullable = any(MODEL[child]['cols'][c]['nullable'] for c in fk['cols'])
    sa = 'ERzeroToOne' if nullable else 'ERone'
    cc = set(fk['cols'])
    uniq = (cc == set(MODEL[child]['pk'])) or any(set(v) == cc and k not in FILTERED
                                                  for k, v in MODEL[child]['uq'].items())
    ea = 'ERzeroToOne' if uniq else 'ERzeroToMany'
    return sa, ea

ok_arrow = True
for e in EDGES:
    cell = edges[e['fk']]
    st = cell.get('style', '')
    sa = re.search(r'startArrow=(\w+)', st).group(1)
    ea = re.search(r'endArrow=(\w+)', st).group(1)
    want = arrows_of(e)
    src = cell.get('source', '')[2:]
    tgt = cell.get('target', '')[2:]
    if (sa, ea) != want or src != e['parent'] or tgt != e['child']:
        ok_arrow = False
        print('   mismatch', e['fk'], (sa, ea), want, src, tgt)
rep(ok_arrow, '35 条边的起止箭头与父/子端点由 DDL 结构推导值逐条一致')

# drawio 折点与内存路由一致
ok_pts = True
for e in EDGES:
    geo = edges[e['fk']].find('.//mxGeometry')
    pts = [(int(float(p.get('x'))), int(float(p.get('y')))) for p in geo.findall('.//mxPoint')]
    full = [e['pts'][0]] + pts + [e['pts'][-1]]
    if full != e['pts']:
        ok_pts = False
        print('   point mismatch', e['fk'], full, e['pts'])
rep(ok_pts, 'drawio 折点序列与路由模型逐点一致（35/35）')

# ---------------- 2. business-rule-mapping 35/35 对账 ----------------
mapping = read(r'\docs\stage2\business-rule-mapping.md')
rows = {}
for line in mapping.split('\n'):
    m = re.match(r'\|\s*(BR-\d+)\s*\|\s*(FK_\w+)\s*\|\s*([^|]+?)\s*\|\s*([^|]+?)\s*\|\s*([^|]+?)\s*\|', line)
    if m:
        rows[m.group(1)] = {'fk': m.group(2), 'rel': m.group(3), 'perC': m.group(4), 'perP': m.group(5)}
rep(len(rows) == 35, 'business-rule-mapping 表行数 = %d（期望 35）' % len(rows))
rep(set(rows[r]['fk'] for r in rows) == set(ALL_FK), 'mapping 外键名集合与 sql 源码 35 个外键一致')
ok_br = True
for e in EDGES:
    row = rows.get(e['br'])
    if not row or row['fk'] != e['fk']:
        ok_br = False
        print('   BR/FK mismatch', e['br'], row)
        continue
    rel = row['rel']
    m = re.match(r'(\w+)\s*←\s*(\w+)\.(\w+)', rel)
    if not m:
        ok_br = False
        print('   rel unparsed', e['br'], rel)
        continue
    parent, child, col = m.groups()
    if parent != e['parent'] or child != e['child']:
        ok_br = False
        print('   parent/child mismatch', e['br'], parent, child)
    sa, ea = arrows_of(e)
    wantC = '1' if sa == 'ERone' else '0..1'
    wantP = '0..1' if ea == 'ERzeroToOne' else '0..N'
    if row['perC'] != wantC or row['perP'] != wantP:
        ok_br = False
        print('   cardinality mismatch', e['br'], row['perC'], row['perP'], 'want', wantC, wantP)
rep(ok_br, 'BR 端基数与 DDL 推导逐条一致（父端 1/0..1、子端 0..N/0..1）')

# ---------------- 3. SVG 实际几何 ----------------
svg = read(r'\docs\er\stage2-model.svg')
sroot = ET.fromstring(svg)
NS = '{http://www.w3.org/2000/svg}'
boxes = []
for r in sroot.findall(NS + 'rect'):
    if r.get('width') == '300':
        boxes.append((float(r.get('x')), float(r.get('y')),
                      float(r.get('x')) + 300, float(r.get('y')) + float(r.get('height'))))
rep(len(boxes) == 25, 'SVG 实体矩形数 = %d（期望 25）' % len(boxes))

def inside(x, y, b, pad=1.0):
    return b[0] + pad < x < b[2] - pad and b[1] + pad < y < b[3] - pad

bad = 0
lines = [l for l in sroot.findall(NS + 'line') if l.get('stroke-width') == '1.2']
for l in lines:
    x1, y1, x2, y2 = (float(l.get(k)) for k in ('x1', 'y1', 'x2', 'y2'))
    n = max(2, int(max(abs(x2 - x1), abs(y2 - y1)) / 2))
    for i in range(n + 1):
        x = x1 + (x2 - x1) * i / n
        y = y1 + (y2 - y1) * i / n
        if any(inside(x, y, b) for b in boxes):
            bad += 1
            break
rep(bad == 0, 'SVG 线段采样无穿越实体盒（线段数 %d，穿盒 %d）' % (len(lines), bad))

labels = []
for r in sroot.findall(NS + 'rect'):
    if r.get('height') == '16' and r.get('width') != '300':
        labels.append((float(r.get('x')), float(r.get('y')),
                       float(r.get('x')) + float(r.get('width')), float(r.get('y')) + 16))
rep(len(labels) == 35, 'SVG 联系标签背景框数 = %d（期望 35）' % len(labels))
badl = 0
for a in labels:
    if any(not (a[2] <= b[0] or b[2] <= a[0] or a[3] <= b[1] or b[3] <= a[1]) for b in boxes):
        badl += 1
rep(badl == 0, '标签不压实体盒（压框 %d）' % badl)
badll = 0
for i in range(len(labels)):
    for j in range(i + 1, len(labels)):
        a, b = labels[i], labels[j]
        if not (a[2] <= b[0] + 1 or b[2] <= a[0] + 1 or a[3] <= b[1] + 1 or b[3] <= a[1] + 1):
            badll += 1
rep(badll == 0, '标签互不重叠（重叠对 %d）' % badll)

# SVG 文本逐名出现
texts = [t.text or '' for t in sroot.findall(NS + 'text')]
for t in MODEL:
    rep(t in texts, 'SVG 含实体名 %s' % t)
for e in EDGES:
    rep(e['br'] in texts, 'SVG 含联系标签 %s' % e['br'])

# ---------------- 4. 字节 ----------------
raw = readb(r'\docs\er\stage2-model.drawio')
raws = readb(r'\docs\er\stage2-model.svg')
for name, raw in (('drawio', raw), ('svg', raws)):
    rep(not raw.startswith(b'\xef\xbb\xbf'), '%s 无 BOM' % name)
    rep(raw.count(b'\r\n') == raw.count(b'\n') and raw.endswith(b'\r\n'),
        '%s 全 CRLF 且末尾换行（行数 %d）' % (name, raw.count(b'\r\n')))

# ---------------- 5. 汇总 ----------------
print('\nRESULT: pass=%d fail=%d' % (passes[0], len(fails)))
if fails:
    raise SystemExit(1)
