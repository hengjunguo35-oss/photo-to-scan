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
#    第 6 个字段以前永远是空的（引擎只报数量、不报名字），现在由引擎的
#    BATCH 行第 4 个字段提供，转成空格分隔后放进这里，外壳才能真正显示
#    「失败：xxx.jpg」。
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
# 引擎在 stdout 最后打印：BATCH|<成功>|<失败>|<失败文件名，分号分隔>
# 如果没解析到（比如引擎崩溃），就按退出码粗略判断，保证外壳总能拿到合法返回值。
ok=0; bad=0; failed=""
have_result=0
line="$(grep -a '^BATCH|' "$LOGFILE" | tail -1)"
if [ -n "$line" ]; then
  have_result=1
  ok="$(echo "$line" | cut -d'|' -f2)"
  bad="$(echo "$line" | cut -d'|' -f3)"
  failed="$(echo "$line" | cut -d'|' -f4)"
elif [ "$rc" -eq 0 ]; then
  have_result=1
  ok="${#files[@]}"
else
  # 引擎整个挂掉（崩溃、二进制缺失…）：既没有名单，也不知道谁成功，
  # 只能全部计为失败，并且**一个源文件都不归档**（见下面的 have_result 判断）
  bad="${#files[@]}"
fi

# ── 归档源文件（★ 只归档成功的）──
# 只有「待扫描」模式才归档（避免下次重复处理同一张）。
# 拖拽进来的文件是用户自己的，动它不礼貌，原地不动。
#
# 关键修正：以前只要 ok != 0 就把**全部**源文件移走，包括失败的 ——
# 于是失败的照片既没提示、又消失不见，用户会以为全部成功。
# 现在失败的留在「待扫描」，下次双击就能重试。
# ★ 只有「确知哪些成功」时才归档。
#   引擎整个挂掉时 have_result=0，此时失败名单是空的 —— 若照旧逻辑遍历归档，
#   会把**一张都没处理过**的源文件全部移走，用户彻底懵。
if [ "$from_args" -eq 0 ] && [ "$have_result" -eq 1 ]; then
  for f in "${files[@]}"; do
    stem="$(basename "${f%.*}")"
    case ";${failed};" in
      *";${stem};"*) continue ;;     # 在失败名单里 → 留在原处，方便重试
    esac
    [ -f "$f" ] && mv -f "$f" "$DONE/" 2>/dev/null
  done
fi

# 失败名单转成空格分隔，供外壳直接拼进提示文字
failed_display="$(echo "$failed" | tr ';' ' ' | sed 's/^ *//;s/ *$//')"

echo "RESULT|$ok|$bad|$OUTDIR|$INBOX|$failed_display"
exit 0
