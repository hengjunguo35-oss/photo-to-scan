# photo-to-scan

> 一个开源免费的图片扫描工具

把「手机拍的纸质文件照片」变成扫描件——自动找到纸张、裁掉桌面和键盘、拉正透视与方向、
消掉阴影把纸面压成纯白，同时**原样保留手写笔迹和稿纸上的红色格线**。

**不做 OCR、不重排文字、不用生成式模型补像素。** 手写内容始终是原始像素。

📖 **想深入了解原理、技术选型和环境配置，请看 [技术文档.md](技术文档.md)。**

> Turn a phone photo of a paper document into a clean scan: auto paper detection,
> perspective correction, deskew, shadow removal, pure-white background — while
> **preserving handwriting and printed ruling lines as raw pixels**.
> No OCR, no document reconstruction, no generative inpainting.
> macOS 13+, zero third-party dependencies.

---

## 为什么值得单独做一个

现成的开源扫描工具几乎都会在最后一步做**自适应二值化**（Sauvola / Wolf / Otsu / unpaper / textcleaner）。
这对普通文档没问题，但对**中国稿纸**是灾难：

> 红色格线在亮度上非常接近纸白。二值化会**直接把格线抹掉**，灰度化则会**毁掉它的红色**。

所以这个项目的核心约束是：**全程留在 RGB 空间，绝不二值化。**
这条约束排除了绝大多数现成方案，也是这个项目存在的理由。

## 环境要求

- macOS **13.0+**（用到系统自带的 Vision 文档分割 API）
- 构建需要 Xcode 或 Command Line Tools（`xcode-select --install`）
- **运行时零第三方依赖**：只用系统框架（Vision / CoreImage / CoreGraphics / ImageIO）
- 中文路径提示：本项目编译时会把模块缓存放到 `/tmp`。
  若把 `CLANG_MODULE_CACHE_PATH` / `TMPDIR` 指到含中文的路径，
  Swift 5.9 的编译器会直接 `SIGILL` 崩溃（exit 132）——踩过一次，见 `app/build-app.sh` 注释。

## 快速开始

```bash
# 1. 编译引擎
swiftc -O src/scan.swift -o scan

# 2. 单张处理 -> PNG + A4 PDF
./scan process 照片.jpg 输出.png --pdf 输出.pdf

# 3. 批量处理（推荐）
./scan batch 输出目录/ 照片1.jpg 照片2.jpg 照片3.jpg
```

### 做成双击即用的 App

```bash
./app/build-app.sh          # 默认编通用二进制（x86_64 + arm64）
open photo-to-scan.app
```

生成的 `.app` 支持两种用法：

- **双击** → 处理 `~/Documents/扫描仪/待扫描/` 里的全部图片
- **把照片拖到图标上** → 立即处理这一批

产出落在 `~/Documents/扫描仪/扫描件输出/`，处理完的原始照片自动归档到 `已扫描/`。

## 参数

| 参数 | 默认 | 说明 |
|---|---|---|
| `--rot auto\|cw\|ccw\|0\|180` | `auto` | 旋转方向。`auto` 用投影方差比判断横竖，用「红色抬头在顶部」判断 0/180 与 cw/ccw |
| `--nodeskew` | 关 | 关闭自动纠偏 |
| `--skewgain N` | `1.15` | 纠偏生效阈值：投影方差至少提升 N 倍才动手 |
| `--noflatten` | 关 | 关闭去阴影/增白（照片光照本就很均匀时用） |
| `--bw` | 关 | 输出灰度高对比版本（红格线会变灰） |
| `--inset N` | `8` | 四边内缩像素，去掉照片边缘残留的桌面颜色 |

## 性能：为什么一定要用 batch

Vision 的文档分割模型**每次启动进程都要重新加载**。在 2017 款 Intel Core m3 上实测：

| 方式 | 耗时 |
|---|---|
| 单张（process） | 约 30 秒（其中 29 秒是模型加载） |
| 批量 3 张（batch） | **17 秒**（模型只加载一次，之后每张约 1 秒） |

**哪怕只有 2 张也请走 `batch`。** 在 Apple Silicon 上模型加载会快一个数量级。

## 处理流程

1. **找纸张** — 优先用纸上的「印刷彩色边框」（纯像素运算，毫秒级；用印刷边框做几何基准
   比纸张外缘更准）。但边框残缺时必须放弃：`frameQuad` 有**覆盖度校验**，
   任一条边覆盖率 < 0.70 就退回 Vision 文档分割——**宁可慢，也不冒险裁掉正文**。
2. **透视校正** — `CIPerspectiveCorrection`
3. **自动定向** — 行/列投影方差比判断文字行横竖；红色抬头位置定 0/180 与 cw/ccw
4. **自动纠偏** — 投影轮廓法在 ±3° 内搜索让墨迹行投影方差最大的剪切量，
   转掉残余倾斜，按内接矩形裁掉旋转白角。带自检回退。
   实测把 **−1.025° 修到 0.000°**
5. **去阴影增白** — 原图除以自身的大幅高斯模糊灰度图（`CIDivideBlendMode`）。
   阴影是低频、笔迹是高频，一除就把光照分量消掉，只留反射率。
   注意该滤镜方向是「背景图 = 原图」，写反了整页会发白。
6. `CINoiseReduction` + `CIToneCurve` + `CIColorControls` + `CIUnsharpMask`
7. 内缩去边 → 300dpi PNG + A4 PDF

## 质量验证

```bash
python3 tools/measure.py 成品.png
```

三个可靠指标：

- **残余倾斜** 应接近 `0.000 deg`
- **最外圈偏离像素占比** 应 < 0.02（边缘没有残留桌面颜色）
- **纸面众数** 应为 255

`measure.py` 里的「空白带灰度」会被横穿的红格线干扰，**不要**用它判断白度。
另外**不要只跑测量就交付**，还要目视确认格线水平、标题没被裁。

## 排错

| 现象 | 处理 |
|---|---|
| 方向转错 | `--rot cw` / `--rot ccw` 手动指定 |
| 格线还是歪 | 看日志 `deskew:` 行；若 `variance gain < 1.15` 说明没有明显行结构，可加 `--skewgain 1.02` |
| 纸面发灰 | 检查是否误加了 `--noflatten` |
| 裁掉了正文 | 纸张检测偏了，看日志 `quad source:` 是 `printed frame` 还是 `Vision document segmentation` |
| 单张特别慢 | 正常（模型加载）。改用 `batch` |

## 目录结构

```
src/scan.swift            引擎（全部算法与滤镜管线）
app/applet.applescript    App 的拖拽/双击外壳
app/scan-worker.sh        工作目录管理、批量调度、防重名
app/build-app.sh          打包成 .app（通用二进制）
tools/measure.py          成品客观质量测量
```

## 隐私

**完全离线。** 引擎只链接系统框架（无 CFNetwork / Network.framework），
源码中不含任何联网调用，App 的 entitlements 为空。
实测：跑完整扫描全程 `lsof -i` 监控到 **0 次网络连接**。
「智能」全部来自 Apple 的端上模型（CoreML）与本地 CoreImage 运算。

## English summary

`photo-to-scan` converts a phone photo of a paper document into a clean scan on macOS —
auto page detection, perspective correction, deskew, shadow removal via division-based
illumination flattening, and a pure-white background, while keeping handwriting and
printed ruling lines as raw pixels.

The key design constraint: **stay in RGB and never binarise.** Red ruling on Chinese
manuscript paper sits very close to paper-white in luminance, so the adaptive
thresholding that nearly every scanner pipeline ends with would erase it outright.

Zero third-party dependencies (system Vision + CoreImage only), fully offline.
macOS 13+.

## License

MIT — 见 [LICENSE](LICENSE)。
