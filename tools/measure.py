#!/usr/bin/env python3
# ============================================================================
#  measure.py — 扫描件成品质量测量
# ============================================================================
#
#  为什么需要这个脚本
#  ------------------
#  扫描件好不好，肉眼看不准，尤其是「格线有没有歪 1°」这种问题 ——
#  盯着看会觉得自己看错了。开发过程中正是靠这个脚本才发现初版成品的
#  红格线还残留着 −1.025° 的倾斜，而当时肉眼看图完全没察觉。
#
#  用法
#  ----
#      python3 measure.py 成品A.png 成品B.png
#
#  三个可靠指标（判断成品合格与否就看这三个）
#  ------------------------------------------
#    · 残余倾斜        应接近 0.000 deg
#    · 最外圈偏离占比  应 < 0.02（说明边缘没有残留的桌面颜色）
#    · 纸面众数        应为 255（另见 README 的亮度分布检查）
#
#  ⚠️ 一个会骗人的指标：「空白带灰度」
#      它取的横向条带会横穿红格线，所以均值和标准差都被红线污染了。
#      红格线越水平，条带里的红线越集中，标准差反而越大 —— 看起来像「变差了」，
#      实际是**变好了**。别用它判断白度，用全图亮度分布（众数 / P95）才对。
#
#  依赖：Pillow（唯一依赖）
# ============================================================================

import sys

from PIL import Image, ImageChops, ImageStat


def rowvar(mask):
    """「行投影方差」—— 本文件里所有倾斜判断的基础。

    把掩膜按行压成一列（BOX 重采样 = 每行取均值），得到一个
    「每一行有多少墨迹」的数列，返回它的方差。

    方差越大 = 墨迹越集中在少数几行 = 格线越水平。
    这正是主程序里 estimateShear() 用的同一个原理（投影轮廓法），
    只是这里是拿成品来复测，属于独立验证。
    """
    s = mask.resize((1, mask.height), Image.BOX)
    px = list(s.getdata())
    n = len(px)
    m = sum(px) / n
    return sum((v - m) ** 2 for v in px) / n


def measure(path):
    im = Image.open(path).convert("RGB")
    W, H = im.size

    # ── 红色掩膜：用于倾斜检测 ──
    # 只取红色（r 明显大于 g 和 b），因为格线是红的，比手写笔迹规则得多，
    # 用它测倾斜的信噪比最高。
    r, g, b = im.split()
    mx = ImageChops.lighter(g, b)
    red = ImageChops.subtract(r, mx).point(lambda v: 255 if v > 28 else 0)
    redfrac = ImageStat.Stat(red).mean[0] / 255

    # ── 细搜残余倾斜：±1.5°，步长 0.025° ──
    # 取让行投影方差最大的那个角度。若最佳角度明显偏离 0，
    # 说明成品的格线还是歪的。
    best, bv = 0.0, -1.0
    i = -60
    while i <= 60:
        a = i * 0.025
        v = rowvar(red.rotate(a, resample=Image.BILINEAR, fillcolor=0))
        if v > bv:
            bv, best = v, a
        i += 1
    v0 = rowvar(red)          # 不旋转时的方差，作为基准

    # ── 纸面纯度：取中下部空白带（避开红线和字）──
    # ⚠️ 见文件头的警告：这个条带会横穿红格线，指标会被污染，
    #    只作参考，不要作为合格判据。
    band = im.crop((int(W * 0.15), int(H * 0.78), int(W * 0.85), int(H * 0.92))).convert("L")
    st = ImageStat.Stat(band)
    nonwhite = sum(1 for v in band.getdata() if v < 250) / (band.width * band.height)

    # ── 边缘杂色：最外两圈像素偏离纯白的程度 ──
    # 透视校正 + 内缩之后，边缘不该再有桌面/键盘的残留颜色。
    # 这是判断 --inset 参数是否够用的依据。
    edge = []
    px = im.load()
    for x in range(W):
        edge += [px[x, 0], px[x, 1], px[x, H - 1], px[x, H - 2]]
    for y in range(H):
        edge += [px[0, y], px[1, y], px[W - 1, y], px[W - 2, y]]
    worst = max((255 - min(p)) for p in edge)
    edge_off = sum(1 for p in edge if min(p) < 245) / len(edge)

    print(f"--- {path}")
    print(f"    尺寸        {W}x{H}  宽高比 {W/H:.4f}")
    print(f"    红色占比    {redfrac:.4f}")
    print(f"    残余倾斜    {best:+.3f} deg   (方差 {bv:.0f} vs 未纠偏 {v0:.0f})")
    print(f"    空白带灰度  均值 {st.mean[0]:.1f}  标准差 {st.stddev[0]:.1f}  非纯白占比 {nonwhite:.4f}")
    print(f"    最外圈      最大偏离纯白 {worst}  偏离像素占比 {edge_off:.4f}")
    return best, st.mean[0], edge_off


if __name__ == "__main__":
    if len(sys.argv) < 2:
        print(__doc__ or "用法: python3 measure.py <成品.png> [更多成品.png ...]")
        sys.exit(1)
    for p in sys.argv[1:]:
        measure(p)
        print()
