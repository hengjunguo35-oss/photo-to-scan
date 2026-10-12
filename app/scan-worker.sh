#!/bin/bash
# ============================================================================
#  scan-worker.sh — 「扫描仪.app」与扫描引擎之间的调度层
# ============================================================================
#
#  职责
#  ----
#    1. 准备/管理四个工作文件夹（待扫描 / 扫描件输出 / 已扫描 / 日志）
#    2. 决定这一批要处理哪些文件
#    3. 把整批文件**一次性**交给 scan 的 batch 模式
#    4. 把结果整理成一个固定格式的返回值给 AppleScript 外壳
#
#  两种调用方式
#  ------------
#    带参数  → 处理这些文件（用户把照片拖到 App 图标上）
#    不带参数 → 处理「待扫描」文件夹里的全部图片（用户双击 App）
#
#  ★ 为什么必须走 batch 而不是循环调用 process
#  ------------------------------------------
#    Vision 的纸张检测模型**每启动一次进程就要重新加载**，本机实测约 20~30 秒。
#    如果循环调用 process，10 张照片就是 10 次模型加载 = 5 分钟。
#    交给 batch 后模型只加载一次，实测 3 张共 17 秒、之后每张约 1 秒。
#
#  返回值协议（给 AppleScript 解析，字段用 | 分隔）
#  ------------------------------------------------
#    RESULT|<成功数>|<失败数>|<输出目录>|<待扫描目录>|<失败文件名列表>
#
#  环境变量
#  --------
#    SCAN_WORKDIR   自定义工作文件夹，默认 ~/Documents/扫描仪
#                   （App 允许用它把工作目录挪到别处）
# ============================================================================

set -uo pipefail

# ── 路径：全部相对本脚本所在目录（即 .app 内部的 Resources/scan-tool/）──
HERE="$(cd "$(dirname "$0")" && pwd)"
BIN="$HERE/scan"
WORKDIR="${SCAN_WORKDIR:-$HOME/Documents/扫描仪}"
INBOX="$WORKDIR/待扫描"
OUTDIR="$WORKDIR/扫描件输出"
DONE="$WORKDIR/已扫描"
LOGDIR="$WORKDIR/日志"
mkdir -p "$INBOX" "$OUTDIR" "$DONE" "$LOGDIR"

# ── 决定处理哪些文件 ──
files=()
from_args=0
if [ "$#" -gt 0 ]; then
  # 拖拽进来的路径
  from_args=1
  for f in "$@"; do [ -f "$f" ] && files+=("$f"); done
else
  # 「待扫描」文件夹。nullglob 让没有匹配时返回空数组而不是字面量；
  # nocaseglob 让 *.jpg 也能匹配 .JPG（手机导出的文件大小写很随意）
  shopt -s nullglob nocaseglob
  for f in "$INBOX"/*.jpg "$INBOX"/*.jpeg "$INBOX"/*.png "$INBOX"/*.heic \
           "$INBOX"/*.tif "$INBOX"/*.tiff "$INBOX"/*.webp "$INBOX"/*.bmp; do
    [ -f "$f" ] && files+=("$f")
  done
fi

# 没有可处理的文件：返回全零，外壳会提示「文件夹是空的」
if [ "${#files[@]}" -eq 0 ]; then
  echo "RESULT|0|0|$OUTDIR|$INBOX|"
  exit 0
fi

# ── 一次性批量处理 ──
# 引擎的完整日志（含各阶段耗时）重定向到日志文件，方便出问题时排查
LOGFILE="$LOGDIR/运行记录-$(date +%Y%m%d-%H%M%S).log"
"$BIN" batch "$OUTDIR" "${files[@]}" >"$LOGFILE" 2>&1
rc=$?

# ── 从日志里解析批量结果 ──
# 引擎在 stdout 最后打印一行 BATCH|<ok>|<bad>。
# 如果没解析到（比如引擎崩溃），就按退出码粗略判断，保证外壳总能拿到合法返回值。
ok=0; bad=0
line="$(grep -a '^BATCH|' "$LOGFILE" | tail -1)"
if [ -n "$line" ]; then
  ok="$(echo "$line" | cut -d'|' -f2)"
  bad="$(echo "$line" | cut -d'|' -f3)"
elif [ "$rc" -eq 0 ]; then
  ok="${#files[@]}"
else
  bad="${#files[@]}"
fi

# ── 归档源文件 ──
# 只有「待扫描」模式才归档（避免下次重复处理同一张）。
# 拖拽进来的文件是用户自己的，动它不礼貌，原地不动。
if [ "$from_args" -eq 0 ] && [ "${ok:-0}" != "0" ]; then
  for f in "${files[@]}"; do [ -f "$f" ] && mv -f "$f" "$DONE/" 2>/dev/null; done
fi

echo "RESULT|$ok|$bad|$OUTDIR|$INBOX|"
exit 0
