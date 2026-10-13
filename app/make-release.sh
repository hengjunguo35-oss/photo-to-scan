#!/bin/bash
# ============================================================================
#  make-release.sh — 生成正式版安装包（DMG + ZIP）并计算校验和
# ============================================================================
#
#  用法:
#      ./make-release.sh [版本号]        默认 1.0.0
#
#  产物（都在 dist/ 下）:
#      photo-to-scan-<版本>.dmg              推荐给最终用户：打开后拖进「应用程序」
#      photo-to-scan-<版本>-macos.zip        备用：解压即得 .app
#      SHA256SUMS.txt                        校验和，防止下载损坏
#
#  ── 为什么要同时出两种格式 ──
#    · DMG：macOS 的标准分发方式，用户双击挂载、拖拽安装，体验最顺
#    · ZIP：体积略小，且在没有图形界面的环境（比如脚本、CI）里更好处理
#
#  ── 为什么 ZIP 用 ditto 而不是 zip 命令 ──
#    .app 是个目录束（bundle），内含符号链接和扩展属性。
#    普通 zip 会破坏这些，导致解压后 App 无法启动。
#    ditto 是 macOS 原生的、能完整保留 bundle 结构的打包工具。
# ============================================================================

set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$DIR/.." && pwd)"
VERSION="${1:-1.0.0}"
APPNAME="photo-to-scan"
DIST="$ROOT/dist"
APP="$DIST/$APPNAME.app"

echo "════════════════════════════════════════"
echo "  打包 $APPNAME v$VERSION"
echo "════════════════════════════════════════"

rm -rf "$DIST"
mkdir -p "$DIST"

# ── 1. 构建通用二进制的 .app ──
echo "[1/4] 构建 App…"
SCAN_VERSION="$VERSION" "$DIR/build-app.sh" "$DIST" >/dev/null
echo "      引擎架构: $(lipo -archs "$APP/Contents/Resources/scan-tool/scan")"

# ── 2. 写安装说明到打包暂存目录 ──
# ★ 注意：这份说明必须放进**暂存目录**，而不是 $DIST 顶层。
#   之前它写在 $DIST 下，但 DMG 只打包了 .app、ZIP 也只 ditto 了 .app，
#   结果用户拿到安装包时根本看不到这份说明。
echo "[2/4] 写入安装说明…"
STAGE="$DIST/Photo2Scan-$VERSION"
rm -rf "$STAGE"
mkdir -p "$STAGE"
cat > "$STAGE/安装说明.txt" <<'EOF'
Photo2Scan —— 把纸质文件的照片变成扫描件

【安装】
  把 photo-to-scan.app 拖进「应用程序」文件夹即可。

【首次打开被 macOS 拦截？】
  因为本程序没有 Apple 开发者签名（那需要每年 99 美元的开发者账号），
  macOS 会提示「无法验证开发者」。两种解决办法：

    方法一（推荐）：右键点 App → 选择「打开」→ 再点「打开」
                   只需做一次，之后双击就能正常启动

    方法二（命令行）：xattr -dr com.apple.quarantine /Applications/photo-to-scan.app

【使用】
  双击图标      → 处理 ~/Documents/扫描仪/待扫描/ 里的全部图片
  拖照片到图标  → 立即处理这一批照片

  成品落在 ~/Documents/扫描仪/扫描件输出/，每张照片得到一份 PNG + 一份 A4 PDF。

【注意】
  本程序全程在本机运行，不联网、不上传，不做 OCR、不重写手写内容。
  仅供个人学习交流使用，禁止转售。详见项目仓库的 LICENSE 与免责声明。
EOF

# ── 3. 打包 DMG 和 ZIP ──
echo "[3/4] 打包 DMG 与 ZIP…"
DMG="$DIST/$APPNAME-$VERSION.dmg"
ZIP="$DIST/$APPNAME-$VERSION-macos.zip"

# .app 复制进暂存目录，与安装说明放在一起
cp -R "$APP" "$STAGE/"

# DMG：暂存目录的**内容**（.app + 安装说明.txt）落在 DMG 根目录
hdiutil create -volname "Photo2Scan $VERSION" \
  -srcfolder "$STAGE" \
  -ov -format UDZO "$DMG" >/dev/null

# ZIP：ditto 保留 bundle 结构与扩展属性。
# 不加 --keepParent，让解压后直接得到 .app 和 安装说明.txt（而不是多一层文件夹）
ditto -c -k --sequesterRsrc "$STAGE" "$ZIP"

# 暂存目录只用于打包，产物已生成，清掉避免混进 dist 列表
rm -rf "$STAGE"

# ── 4. 校验和 ──
echo "[4/4] 计算校验和…"
( cd "$DIST" && shasum -a 256 "$(basename "$DMG")" "$(basename "$ZIP")" > SHA256SUMS.txt )

echo
echo "════════════════════════════════════════"
echo "  产物（${DIST}）"
echo "════════════════════════════════════════"
ls -lh "$DIST" | tail -n +2 | awk '{printf "  %-42s %s\n", $NF, $5}'
echo
cat "$DIST/SHA256SUMS.txt" | sed 's/^/  /'
