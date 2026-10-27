# -*- coding: utf-8 -*-
"""C 域 ER 子图几何自查：每条联系（含折线）采样 400 点，检查是否穿过非端点实体盒。"""
import importlib.util, os

HERE = os.path.dirname(os.path.abspath(__file__))
GEN = os.path.join(HERE, 'gen_c_er.py')
if not os.path.exists(GEN):
    GEN = r'D:\DBLab\_kfcdb_tmp\gen_c_er.py'
spec = importlib.util.spec_from_file_location('gen', GEN)
gen = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gen)  # 同时会重新生成 drawio/svg

BOX_W = gen.BOX_W


def segments_for(src, dst):
    se = next(e for e in gen.ENTS if e[0] == src)
    de = next(e for e in gen.ENTS if e[0] == dst)
    wp = gen.WAYPOINTS.get((src, dst))
    if wp:
        return list(zip(wp['pts'], wp['pts'][1:]))
    scx, scy = gen.center(se)
    dcx, dcy = gen.center(de)
    p1 = gen.clip_to_rect(scx, scy, dcx, dcy, se[2], se[3], BOX_W, gen.ent_height(se))
    p2 = gen.clip_to_rect(dcx, dcy, scx, scy, de[2], de[3], BOX_W, gen.ent_height(de))
    return [(p1, p2)]


def inside(px, py, e, m=2.0):
    x, y, w = e[2], e[3], BOX_W
    h = gen.ent_height(e)
    return (x + m) < px < (x + w - m) and (y + m) < py < (y + h - m)


hits = 0
for src, dst, sa, ea, label, dashed in gen.EDGES:
    for (x1, y1), (x2, y2) in segments_for(src, dst):
        for i in range(401):
            t = i / 400.0
            px, py = x1 + (x2 - x1) * t, y1 + (y2 - y1) * t
            for e in gen.ENTS:
                if e[0] in (src, dst):
                    continue
                if inside(px, py, e):
                    print('穿盒: {}→{} 段({:.0f},{:.0f})-({:.0f},{:.0f}) 穿过 {} @({:.0f},{:.0f})'
                          .format(src, dst, x1, y1, x2, y2, e[1], px, py))
                    hits += 1
                    break
            else:
                continue
            break  # 该段已命中，进入下一段

# 画布越界检查（线段与标签白底）
print('---')
for src, dst, sa, ea, label, dashed in gen.EDGES:
    for (x1, y1), (x2, y2) in segments_for(src, dst):
        if min(x1, x2) < 0 or max(x1, x2) > 1500 or min(y1, y2) < 0 or max(y1, y2) > 940:
            print('越界: {}→{} 段({:.0f},{:.0f})-({:.0f},{:.0f})'.format(src, dst, x1, y1, x2, y2))
            hits += 1
print('几何冲突总数:', hits)
