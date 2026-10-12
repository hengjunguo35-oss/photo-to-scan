#!/bin/bash
# ============================================================================
#  build-app.sh — 把命令行引擎打包成双击即用的「Photo2Scan.app」
# ============================================================================
#
#  用法
#  ----
#      ./build-app.sh [输出目录]             默认输出到本目录
#      ./build-app.sh --native [输出目录]    只编当前机器的架构（更快）
#
#  产物是一个**自包含**的 .app：Swift 引擎的编译结果直接嵌在 bundle 里，
#  拷到别的 Mac 上也能跑（对方不需要装 Xcode，也不需要本项目源码）。
#
#  ── 为什么要编「通用二进制」──
#    只编当前架构的话，在 Intel 机器上编出来的包拿到 M 系列 Mac 上要靠
#    Rosetta 才能跑。所以默认分别编 x86_64 和 arm64，再用 lipo 合并。
#
#  ── ★ 一个非常隐蔽的坑：编译中间产物必须放在纯 ASCII 路径 ──
#    如果把 CLANG_MODULE_CACHE_PATH / TMPDIR 指向含中文的路径，
#    Swift 5.9 的编译器会直接 SIGILL 崩溃，报 "Illegal instruction: 4"（exit 132），
#    而且不给出任何有意义的错误信息 —— 极难排查。
#    本项目最初就踩了这个坑：工作目录改名为「扫描仪-App源码」后编译立刻全崩，
#    排查很久才发现跟架构、跟代码都无关，纯粹是路径里有中文。
#    所以下面用 mktemp -d /tmp/... 强制把缓存放到纯 ASCII 路径。
#
#  依赖：Xcode 或 Command Line Tools（xcode-select --install）
# ============================================================================

set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
NATIVE_ONLY=0
if [ "${1:-}" = "--native" ]; then NATIVE_ONLY=1; shift; fi
OUT="${1:-$DIR}"
APP="$OUT/photo-to-scan.app"
# 输出目录可能不存在：osacompile 不会替你建父目录，只会报一个含糊的
# coreFoundationUnknownErr (-4960)，很难看出是路径问题
mkdir -p "$OUT"

# 纯 ASCII 的临时工作目录（见文件头的坑），退出时自动清理
WORK="$(mktemp -d /tmp/dsh-scan-build.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/mcache" "$WORK/tmp"
export CLANG_MODULE_CACHE_PATH="$WORK/mcache"
export SWIFT_MODULE_CACHE_PATH="$WORK/mcache"
export TMPDIR="$WORK/tmp"

SRC="$DIR/../src/scan.swift"
MINOS="${SCAN_MINOS:-13.0}"      # 可用 SCAN_MINOS 覆盖最低系统版本

build_arch() {  # $1 = x86_64 / arm64
  echo "    编译 $1 (macOS $MINOS+)…"
  swiftc -O -target "$1-apple-macosx$MINOS" "$SRC" -o "$WORK/scan-$1"
}

# ── [1/4] 编译引擎 ──
# -O 开启优化：纠偏算法要跑几十万次内层循环，不开优化会慢好几倍
echo "[1/4] 编译扫描引擎…"
if [ "$NATIVE_ONLY" -eq 1 ]; then
  swiftc -O "$SRC" -o "$WORK/scan-final"
elif build_arch x86_64 && build_arch arm64; then
  lipo -create "$WORK/scan-x86_64" "$WORK/scan-arm64" -output "$WORK/scan-final"
  echo "    通用二进制: $(lipo -archs "$WORK/scan-final")"
else
  # 交叉编译失败（比如缺对应架构的 SDK）就退回单架构，不让构建整体失败
  echo "    跨架构编译失败，退回只编本机架构"
  swiftc -O "$SRC" -o "$WORK/scan-final"
fi

# ── [2/4] 编译 AppleScript 外壳 ──
# osacompile 会检测脚本里的 `on open` 处理器，自动把它编成 droplet 类型，
# 这样 App 才支持「把文件拖到图标上」。注意它每次都会重建整个 bundle，
# 所以资源必须在它之后再拷进去。
echo "[2/4] 编译 AppleScript 外壳…"
rm -rf "$APP"
osacompile -o "$APP" -l AppleScript "$DIR/applet.applescript"

# ── [3/4] 把引擎和调度脚本嵌进 bundle ──
echo "[3/4] 嵌入引擎与工作脚本…"
RES="$APP/Contents/Resources/scan-tool"
mkdir -p "$RES"
cp "$WORK/scan-final" "$RES/scan"
cp "$DIR/scan-worker.sh" "$RES/scan-worker.sh"
chmod +x "$RES/scan" "$RES/scan-worker.sh"

# ── [4/4] 写 Info.plist 并签名 ──
echo "[4/4] 写入 Info.plist 并签名…"
P="$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleName photo-to-scan" "$P" 2>/dev/null \
  || /usr/libexec/PlistBuddy -c "Add :CFBundleName string photo-to-scan" "$P"
/usr/libexec/PlistBuddy -c "Add :CFBundleDisplayName string Photo2Scan" "$P" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Add :CFBundleIdentifier string io.github.photo2scan" "$P" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Add :NSHighResolutionCapable bool true" "$P" 2>/dev/null || true

# ad-hoc 签名（--sign -）。必需的：改动 bundle 内容后不重新签名，
# Gatekeeper 会拒绝启动。ad-hoc 不需要开发者证书，本机自用足够。
# 注意：通过网络传输后文件会带 quarantine 标记，首次打开需右键 →「打开」。
codesign --force --deep --sign - "$APP" 2>/dev/null || echo "    (ad-hoc 签名跳过)"

echo "完成: $APP"
echo "引擎架构: $(lipo -archs "$RES/scan" 2>/dev/null || file -b "$RES/scan")"
