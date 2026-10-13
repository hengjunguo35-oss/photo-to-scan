// ============================================================================
//  scan.swift — 把「纸质文件的照片」处理成扫描件（macOS 原生实现）
// ============================================================================
//
//  ── 一句话原理 ─────────────────────────────────────────────────────────────
//
//  拍照时纸张在画面里是个歪斜的四边形。程序求出那个 3×3 的「单应矩阵
//  (homography)」，把纸张四角精确映射到矩形的四角，其余像素按同一矩阵
//  插值。纸以外的桌面、键盘会被映射到画框之外，「背景杂乱」问题于是自然
//  消失 —— 不是识别出桌椅再擦掉，而是根本没让它们进入画面。
//
//  ── 完整流水线 ─────────────────────────────────────────────────────────────
//
//  入口 runOne()，按顺序调用：
//    ① frameQuad / detectQuad   找纸张四角（快路径 / 慢兜底）
//    ② perspectiveCorrect       透视校正（单应变换）
//    ③ autoOrient               判断该转 0° / 90° / 180° / 270°
//    ④ deskew                   修掉印刷格线的残余倾斜
//    ⑤ scanLook                 去阴影 + 增白 + 锐化（"扫描件质感"来源）
//    ⑥ inset                    四边内缩，去掉边缘残留的桌面颜色
//    ⑦ savePNG / savePDF        输出 300dpi PNG + A4 PDF
//
//  ── ★ 最重要的设计约束：全程留在 RGB 空间，绝不二值化 ─────────────────────
//
//  中国稿纸的红色格线在**亮度上非常接近纸白**。几乎所有现成扫描工具最后
//  都会做自适应阈值化（Sauvola / Wolf / Otsu / unpaper / textcleaner），
//  这会**直接把格线抹掉**；转成灰度则会**毁掉它的红色**。
//  所以本项目所有图像操作都必须是「保色」的。
//
//  这条约束排除了绝大多数现成方案，也正是这个程序存在的理由。
//
//  另外两条铁律：
//    · 不做 OCR、不重排文字
//    · 不用生成式模型补像素（inpainting 会伪造手写笔迹）
//  手写内容必须始终是原始像素。
//
//  ── 编译与使用 ─────────────────────────────────────────────────────────────
//
//    swiftc -O scan.swift -o scan
//    ./scan process 照片.jpg 输出.png --pdf 输出.pdf
//    ./scan batch  输出目录/ 照片1.jpg 照片2.jpg      ← 推荐，模型只加载一次
//
//  ── 依赖 ───────────────────────────────────────────────────────────────────
//
//  仅系统框架，零第三方依赖：
//    Vision       找纸张四角的 CoreML 模型（macOS 自带）
//    CoreImage    各类滤镜
//    CoreGraphics / ImageIO   读写图片与 PDF
//
// ============================================================================
import Foundation
import Vision
import CoreImage
import ImageIO

let ctx = CIContext(options: [.useSoftwareRenderer: false])

/// 日志输出到 stderr。stdout 要留给结构化结果（例如批处理的 `BATCH|ok|bad`），
/// 这样调用方可以直接解析 stdout，人类看 stderr。
func log(_ s: String) { FileHandle.standardError.write((s + "\n").data(using: .utf8)!) }

let T0 = Date()
/// 打印「距程序启动已过多少秒」，用于定位性能瓶颈。
/// 当初正是靠它发现：单张处理耗时 57 秒里，有 50 秒卡在 Vision 模型加载上，
/// 而我自己写的纠偏算法只占 0.28 秒。
func mark(_ s: String) { log(String(format: "[%6.2fs] %@", Date().timeIntervalSince(T0), s)) }

/// 读图片文件为 CGImage。
/// 用 CGImageSource 而非 NSImage：它能直接解 HEIC / TIFF / WebP，
/// 且不依赖 AppKit，让引擎可以完全脱离图形界面运行。
func loadCG(_ path: String) -> CGImage? {
    let url = URL(fileURLWithPath: path)
    guard let s = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
    return CGImageSourceCreateImageAtIndex(s, 0, nil)
}

/// 把 CIImage 的 extent 原点平移回 (0,0)。
/// CoreImage 的滤镜（尤其透视校正和旋转）会产出带偏移的 extent，
/// 不归一化的话，后续所有裁剪坐标都是错的。
func normalizeOrigin(_ img: CIImage) -> CIImage {
    let e = img.extent
    return img.transformed(by: CGAffineTransform(translationX: -e.origin.x, y: -e.origin.y))
}

/// 按 90° 的整数倍旋转图片。rot 取 "cw" / "ccw" / "180" / 其他（不动）。
///
/// ★ 注意符号：CoreImage 坐标系是 y 轴向上，与屏幕坐标相反，
///   所以「视觉上的顺时针 90°」对应 rotationAngle = -π/2（带负号）。
func rotate(_ img: CIImage, _ rot: String) -> CIImage {
    switch rot {
    case "cw":  return normalizeOrigin(img.transformed(by: CGAffineTransform(rotationAngle: -.pi / 2)))
    case "ccw": return normalizeOrigin(img.transformed(by: CGAffineTransform(rotationAngle: .pi / 2)))
    case "180": return normalizeOrigin(img.transformed(by: CGAffineTransform(rotationAngle: .pi)))
    default:    return normalizeOrigin(img)
    }
}

/// 输出 PNG，并写入 DPI 元数据（默认 300），保证打印时物理尺寸正确。
func savePNG(_ image: CIImage, _ path: String, dpi: CGFloat) {
    let img = normalizeOrigin(image)
    guard let cg = ctx.createCGImage(img, from: img.extent) else { log("createCGImage failed"); exit(2) }
    let url = URL(fileURLWithPath: path) as CFURL
    guard let dest = CGImageDestinationCreateWithURL(url, "public.png" as CFString, 1, nil) else {
        log("cannot write \(path)"); exit(2)
    }
    let props: [CFString: Any] = [kCGImagePropertyDPIWidth: dpi, kCGImagePropertyDPIHeight: dpi]
    CGImageDestinationAddImage(dest, cg, props as CFDictionary)
    if !CGImageDestinationFinalize(dest) { log("finalize failed"); exit(2) }
    log("wrote \(path)  \(Int(img.extent.width))x\(Int(img.extent.height))")
}

// ---------- document edge detection ----------
// 快速路径：直接找纸上的「印刷彩色边框」（稿纸的红框、公文的红头框等）。
// 纯像素运算，毫秒级；而且用印刷边框做几何基准比纸张外缘更准 —— 框和格线
// 是同一个版印出来的，用框校正后格线天然水平。
/// 【快速路径】直接从纸上的「印刷彩色边框」求纸张四角。
///
/// ── 为什么优先用它 ──
///   1. 纯像素运算，毫秒级。Vision 的文档分割模型每次启动进程都要重新加载
///      （本机实测 20~30 秒），差距是碾压性的。
///   2. 更准：边框和格线是同一个版印出来的，用边框当几何基准校正之后，
///      格线天然就是水平的，连纠偏（deskew）都省了。
///
/// ── 算法四步 ──
///   ① 取「鲜红」掩膜。判据 r>100 且 r-max(g,b)>55，必须这么严格：
///      木桌的棕色同样饱和，但红分量不会这么突出。
///   ② 用四个极值点（x+y 与 x-y 的最小/最大）作四角初值。
///   ③ 对每条边，取落在该边带状区域内的点做**全最小二乘(PCA)拟合**。
///      注意：不能用「每行最左红像素」那种朴素做法 —— 矩形一旦旋转，
///      最左点会沿着两条边走出一个 V 形，单条直线根本拟合不了。
///   ④ 相邻两条边求交点，得到精确四角。
///
/// ── ★ 覆盖率校验（本函数最关键的部分，别删）──
///   算完四角后，逐条边采样检查红像素覆盖率，任一条 < 0.70 就返回 nil。
///   实测某张照片：右边框覆盖率 1.00，左边框 0.58，上下边框只有 0.08 ——
///   稿纸的短边在那种光照下几乎完全看不见。
///   如果拿这种残缺的边去拟合，会**静默裁掉正文**，而用户根本不会发现。
///   宁可退回慢 30 秒的 Vision，也绝不冒这个险。
///
/// - Returns: 四角，顺序 TL, TR, BR, BL，坐标系为 CIImage（y 轴向上）；
///            边框不完整或形状不合理时返回 nil
func frameQuad(_ img: CIImage) -> [CGPoint]? {
    // 必须接近原分辨率：稿纸边框只有 2~3 像素宽，降采样会把它糊成灰白
    let sw = min(Int(img.extent.width), 2000)
    let sh = max(1, Int(Double(sw) * img.extent.height / img.extent.width))
    let buf = smallBitmap(img, sw, sh)

    var pts: [(Double, Double)] = []
    pts.reserveCapacity(60000)
    for y in 0..<sh {
        let row = y * sw
        for x in 0..<sw {
            let i = (row + x) * 4
            let r = Int(buf[i]), g = Int(buf[i + 1]), b = Int(buf[i + 2])
            // 必须是「红占绝对主导」的鲜红：木桌的棕色也饱和，但红分量不会这么突出
            if r > 100 && r - max(g, b) > 55 { pts.append((Double(x), Double(y))) }
        }
    }
    guard pts.count > 300 else { return nil }
    var grid = [Bool](repeating: false, count: sw * sh)
    for p in pts { grid[Int(p.1) * sw + Int(p.0)] = true }

    // 四个极值点作初值
    var tl = pts[0], tr = pts[0], br = pts[0], bl = pts[0]
    var sTL = Double.infinity, sTR = -Double.infinity, sBR = -Double.infinity, sBL = Double.infinity
    for p in pts {
        let sum = p.0 + p.1, dif = p.0 - p.1
        if sum < sTL { sTL = sum; tl = p }
        if sum > sBR { sBR = sum; br = p }
        if dif > sTR { sTR = dif; tr = p }
        if dif < sBL { sBL = dif; bl = p }
    }

    // 对每条边，取落在该边带内的点做全最小二乘（PCA）拟合
    func fitEdge(_ a: (Double, Double), _ b: (Double, Double), _ band: Double) -> ((Double, Double), (Double, Double))? {
        let dx = b.0 - a.0, dy = b.1 - a.1
        let len = (dx * dx + dy * dy).squareRoot()
        guard len > 1e-6 else { return nil }
        let nx = -dy / len, ny = dx / len
        let c = -(nx * a.0 + ny * a.1)
        var sel: [(Double, Double)] = []
        for p in pts {
            if abs(nx * p.0 + ny * p.1 + c) > band { continue }
            let t = ((p.0 - a.0) * dx + (p.1 - a.1) * dy) / (len * len)
            if t < -0.03 || t > 1.03 { continue }
            sel.append(p)
        }
        guard sel.count >= 10 else { return nil }
        let n = Double(sel.count)
        let mx = sel.reduce(0.0) { $0 + $1.0 } / n
        let my = sel.reduce(0.0) { $0 + $1.1 } / n
        var sxx = 0.0, syy = 0.0, sxy = 0.0
        for p in sel {
            let ux = p.0 - mx, uy = p.1 - my
            sxx += ux * ux; syy += uy * uy; sxy += ux * uy
        }
        // 主轴方向 = 协方差矩阵最大特征值对应的特征向量
        let tr2 = sxx + syy
        let det = sxx * syy - sxy * sxy
        let disc = max(0, tr2 * tr2 / 4 - det).squareRoot()
        let l1 = tr2 / 2 + disc
        var vx = sxy, vy = l1 - sxx
        if abs(vx) < 1e-9 && abs(vy) < 1e-9 { vx = 1; vy = 0 }
        let vl = (vx * vx + vy * vy).squareRoot()
        return ((mx, my), (vx / vl, vy / vl))
    }

    let band = Double(max(sw, sh)) * 0.012
    guard let eT = fitEdge(tl, tr, band), let eR = fitEdge(tr, br, band),
          let eB = fitEdge(br, bl, band), let eL = fitEdge(bl, tl, band) else { return nil }

    func cross(_ f: ((Double, Double), (Double, Double)), _ g: ((Double, Double), (Double, Double))) -> (Double, Double)? {
        let (p, d) = f, (q, e) = g
        let den = d.0 * e.1 - d.1 * e.0
        guard abs(den) > 1e-9 else { return nil }
        let t = ((q.0 - p.0) * e.1 - (q.1 - p.1) * e.0) / den
        return (p.0 + t * d.0, p.1 + t * d.1)
    }
    guard let cTL = cross(eT, eL), let cTR = cross(eT, eR),
          let cBR = cross(eB, eR), let cBL = cross(eB, eL) else { return nil }
    let quad = [cTL, cTR, cBR, cBL]

    // 合理性检查
    let W = Double(sw), H = Double(sh)
    for p in quad where p.0 < -8 || p.0 > W + 8 || p.1 < -8 || p.1 > H + 8 { return nil }
    var area = 0.0
    for i in 0..<4 {
        let p = quad[i], q = quad[(i + 1) % 4]
        area += p.0 * q.1 - q.0 * p.1
    }
    area = abs(area) / 2
    guard area > W * H * 0.12 else { return nil }
    func side(_ p: (Double, Double), _ q: (Double, Double)) -> Double {
        ((p.0 - q.0) * (p.0 - q.0) + (p.1 - q.1) * (p.1 - q.1)).squareRoot()
    }
    let wT = side(quad[0], quad[1]), wB = side(quad[3], quad[2])
    let hL = side(quad[0], quad[3]), hR = side(quad[1], quad[2])
    guard wT > 20, wB > 20, hL > 20, hR > 20,
          min(wT, wB) / max(wT, wB) > 0.4,
          min(hL, hR) / max(hL, hR) > 0.4 else { return nil }

    // 关键校验：每条边沿线必须有足够密集的红像素。
    // 照片里稿纸某条框线太淡是常事（本案左框线几乎不可见），
    // 若只凭残缺的边去拟合，会静默裁掉正文 —— 宁可退回慢速的 Vision。
    func coverage(_ p: (Double, Double), _ q: (Double, Double)) -> Double {
        let steps = 120
        var hit = 0
        for k in 0...steps {
            let t = Double(k) / Double(steps)
            let x = Int((p.0 + (q.0 - p.0) * t).rounded())
            let y = Int((p.1 + (q.1 - p.1) * t).rounded())
            var found = false
            for dy in -2...2 {
                for dx in -2...2 {
                    let xx = x + dx, yy = y + dy
                    if xx >= 0, xx < sw, yy >= 0, yy < sh, grid[yy * sw + xx] { found = true }
                }
                if found { break }
            }
            if found { hit += 1 }
        }
        return Double(hit) / Double(steps + 1)
    }
    let covT = coverage(quad[0], quad[1]), covB = coverage(quad[3], quad[2])
    let covL = coverage(quad[0], quad[3]), covR = coverage(quad[1], quad[2])
    log(String(format: "frame edge coverage: T=%.2f R=%.2f B=%.2f L=%.2f", covT, covR, covB, covL))
    guard min(min(covT, covB), min(covL, covR)) >= 0.70 else {
        log("frame is incomplete -> falling back to Vision")
        return nil
    }

    // 掩膜坐标（行 0 = 图像顶部）换算回 CIImage 坐标（y 轴向上）
    let Wr = Double(img.extent.width), Hr = Double(img.extent.height)
    return quad.map { CGPoint(x: $0.0 * Wr / W, y: Hr - $0.1 * Hr / H) }
}

/// 【慢速兜底路径】用 Apple Vision 的文档分割模型找纸张四角。
///
/// VNDetectDocumentSegmentationRequest 是 macOS 自带的 CoreML 模型，对
/// 「白纸放在杂乱背景上」非常鲁棒，但代价是**每次启动进程都要重新加载模型**
/// （2017 款 Intel Core m3 实测约 20~30 秒）。所以只在快速路径失败时使用。
///
/// 若文档分割也失败，再退回 VNDetectRectanglesRequest（纯几何找矩形）。
/// 它鲁棒性差得多，但总比完全没有强。
///
/// 顺带一个实测结论：**降采样救不了这个耗时**。把输入缩到 900px 和 600px，
/// 耗时仍是 25 秒 —— 说明瓶颈在模型加载，不在推理。
///
/// - Returns: (左上, 右上, 左下, 右下)，坐标系为 CIImage
func detectQuad(_ cg: CGImage) -> (CIVector, CIVector, CIVector, CIVector)? {
    let W = CGFloat(cg.width), H = CGFloat(cg.height)
    let handler = VNImageRequestHandler(cgImage: cg, options: [:])

    let doc = VNDetectDocumentSegmentationRequest()
    do { try handler.perform([doc]) } catch { log("segmentation error: \(error)") }
    if let o = doc.results?.first {
        log(String(format: "doc-seg quad: TL(%.3f,%.3f) TR(%.3f,%.3f) BL(%.3f,%.3f) BR(%.3f,%.3f)",
                   o.topLeft.x, o.topLeft.y, o.topRight.x, o.topRight.y,
                   o.bottomLeft.x, o.bottomLeft.y, o.bottomRight.x, o.bottomRight.y))
        // Vision normalized coords: origin bottom-left -> matches CIImage space
        return (CIVector(x: o.topLeft.x * W, y: o.topLeft.y * H),
                CIVector(x: o.topRight.x * W, y: o.topRight.y * H),
                CIVector(x: o.bottomLeft.x * W, y: o.bottomLeft.y * H),
                CIVector(x: o.bottomRight.x * W, y: o.bottomRight.y * H))
    }
    log("doc-seg found nothing, falling back to rectangle detection")

    let rect = VNDetectRectanglesRequest()
    rect.maximumObservations = 1
    rect.minimumConfidence = 0.3
    rect.minimumSize = 0.3
    rect.quadratureTolerance = 30
    do { try handler.perform([rect]) } catch { log("rect error: \(error)"); return nil }
    guard let r = rect.results?.first else { return nil }
    func px(_ p: CGPoint) -> CIVector { CIVector(x: p.x * W, y: p.y * H) }
    return (px(r.topLeft), px(r.topRight), px(r.bottomLeft), px(r.bottomRight))
}

/// 透视校正：把照片里歪斜的纸张「铺平」成正视矩形。
///
/// 优先用印刷边框（快且准），失败则退回 Vision（慢但通用）。
/// 实际变换由 CIPerspectiveCorrection 完成 —— 它内部求解单应矩阵，
/// 并对每个输出像素做反向映射 + 双线性插值重采样。
func perspectiveCorrect(_ img: CIImage, _ cg: CGImage) -> CIImage {
    var q: (CIVector, CIVector, CIVector, CIVector)? = nil
    if let f = frameQuad(img) {
        log(String(format: "quad source: printed frame  TL(%.3f,%.3f) TR(%.3f,%.3f) BL(%.3f,%.3f) BR(%.3f,%.3f)",
                   f[0].x / img.extent.width, 1 - f[0].y / img.extent.height,
                   f[1].x / img.extent.width, 1 - f[1].y / img.extent.height,
                   f[3].x / img.extent.width, 1 - f[3].y / img.extent.height,
                   f[2].x / img.extent.width, 1 - f[2].y / img.extent.height))
        q = (CIVector(cgPoint: f[0]), CIVector(cgPoint: f[1]),
             CIVector(cgPoint: f[3]), CIVector(cgPoint: f[2]))
    } else {
        log("quad source: Vision document segmentation")
        q = detectQuad(cg)
    }
    guard let q else { log("no document boundary found; keeping full frame"); return img }
    let corrected = img.applyingFilter("CIPerspectiveCorrection", parameters: [
        "inputTopLeft": q.0, "inputTopRight": q.1, "inputBottomLeft": q.2, "inputBottomRight": q.3,
    ])
    return normalizeOrigin(corrected)
}

/// 把 CIImage 缩绘进一块 RGBA8 内存缓冲，便于用纯像素循环分析。
///
/// ★★ 极易踩的坑：CGBitmapContext 的内存**第 0 行是图像顶部**，
///    而 CIImage 坐标是 y 轴向上，两者方向相反！
///    也就是说拿到 buf 后按 y 索引时，y=0 对应「视觉顶部」。
///    这个方向我曾经搞反，导致自动定向把页面转了 180°（标题倒过来）。
func smallBitmap(_ img: CIImage, _ sw: Int, _ sh: Int) -> [UInt8] {
    var buf = [UInt8](repeating: 255, count: sw * sh * 4)
    guard let cg2 = ctx.createCGImage(img, from: img.extent) else { return buf }
    buf.withUnsafeMutableBytes { raw in
        if let c = CGContext(data: raw.baseAddress, width: sw, height: sh, bitsPerComponent: 8,
                             bytesPerRow: sw * 4, space: CGColorSpaceCreateDeviceRGB(),
                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
            c.draw(cg2, in: CGRect(x: 0, y: 0, width: sw, height: sh))
        }
    }
    return buf
}

// red-ink bias: manuscript paper puts its big red heading at the TOP of the page,
// which is what breaks the cw/ccw tie that OCR box shape cannot resolve.
/// 「红色抬头在页面顶部」的偏置量 —— 解决 90° 旋转方向无法区分的问题。
///
/// ── 要解决什么 ──
///   投影法只能判断文字行是「横」还是「竖」，但分不清正着还是倒着
///   （转 180° 之后文字行依然是横的）。而稿纸、公文、试卷的顶部都有大块
///   红色抬头，数一数红色像素在上半部多还是下半部多，方向就定下来了。
///
/// - Returns: (上半部红像素数 − 下半部红像素数) / 总红像素数。
///            正值表示红色集中在顶部，即当前方向正确；
///            没有红色（普通黑白文档）时返回 0，由调用方保留原方向。
func redTopBias(_ img: CIImage) -> Double {
    let sw = 120, sh = 180
    let buf = smallBitmap(img, sw, sh)
    var top = 0, bottom = 0, total = 0
    for y in 0..<sh {                      // CGBitmapContext row 0 == TOP of the image
        for x in 0..<sw {
            let i = (y * sw + x) * 4
            let r = Int(buf[i]), g = Int(buf[i + 1]), b = Int(buf[i + 2])
            guard r > 110, r - max(g, b) > 35 else { continue }
            total += 1
            if y < sh / 5 { top += 1 } else if y > sh * 4 / 5 { bottom += 1 }
        }
    }
    guard total > 0 else { return 0 }
    return Double(top - bottom) / Double(total)
}

// 行/列投影方差之比。格线或文字行若是横的，行投影就会剧烈起伏。
// 纯像素运算，不调用 Vision —— Vision 每次请求都要加载 CoreML 模型，开销很大。
/// 行投影方差 ÷ 列投影方差，用来判断文字行（或格线）是横的还是竖的。
///
/// ── 原理 ──
///   横排文字会让「每一行有多少墨迹」这个数列剧烈起伏
///   （有字的行墨迹多，行间空白墨迹少），所以**行投影方差大**；竖排则相反。
///   比值 > 1 说明文字是横排的。
///
/// 纯像素运算，不调 Vision —— 这是把单张处理从 57 秒压到 26 秒的关键改动之一。
/// 实测信号也比 OCR 干净得多：竖线 0.469 vs 横线 2.344，差 5 倍，毫无歧义。
func lineAxisRatio(_ img: CIImage) -> Double {
    let (mask, sw, sh) = inkMask(img, 420)
    var rows = [Double](repeating: 0, count: sh)
    var cols = [Double](repeating: 0, count: sw)
    for y in 0..<sh {
        let r = y * sw
        for x in 0..<sw where mask[r + x] == 1 { rows[y] += 1; cols[x] += 1 }
    }
    func v(_ a: [Double]) -> Double {
        let n = Double(a.count), m = a.reduce(0, +) / n
        return a.reduce(0) { $0 + ($1 - m) * ($1 - m) } / n
    }
    let vc = v(cols)
    return vc > 0 ? v(rows) / vc : 1
}

/// 自动判断页面该旋转多少度，返回 "0" / "cw" / "ccw" / "180"。
///
/// 两步走：
///   ① lineAxisRatio 判断文字行是横是竖 → 决定要不要转 90°
///   ② redTopBias    判断正倒         → 在两个候选方向里选红头朝上的那个
func autoOrient(_ img: CIImage) -> String {
    let r0 = lineAxisRatio(img)
    let rCW = lineAxisRatio(rotate(img, "cw"))
    log(String(format: "auto-orient: lineAxis(0)=%.3f lineAxis(cw)=%.3f", r0, rCW))

    // ── 先判断投影信号是否「明确」──
    // 画面里若有大块非文字内容（例如文档中嵌入的照片），它会冲淡文字行的
    // 投影起伏，使两个方向几乎打平。实测某文档：0.947 vs 1.064 ——
    // 这时再按 "<1.0" 的硬阈值判断，本质上是在抛硬币。
    // 所以信号不够明确（比值 < 1.25）时，改用更稳的版面比例兜底。
    let hi = max(r0, rCW), lo = max(min(r0, rCW), 1e-6)
    if hi / lo < 1.25 {
        let e = img.extent
        let portrait = e.height >= e.width
        log(String(format: "auto-orient: 投影信号不明确（比值 %.2f），改用版面比例 → %@",
                   hi / lo, portrait ? "竖版，不转" : "横版，转 90°"))
        if portrait {
            let b0 = redTopBias(img)
            let b180 = redTopBias(rotate(img, "180"))
            return b0 >= b180 ? "0" : "180"
        }
        let bCW = redTopBias(rotate(img, "cw"))
        let bCCW = redTopBias(rotate(img, "ccw"))
        return bCW >= bCCW ? "cw" : "ccw"
    }

    // 透视校正后页面已是矩形；若横方向的投影起伏更大，说明文字/格线已经是横的
    if r0 < rCW {
        let bCW = redTopBias(rotate(img, "cw"))
        let bCCW = redTopBias(rotate(img, "ccw"))
        log(String(format: "auto-orient: redTopBias(cw)=%.4f redTopBias(ccw)=%.4f", bCW, bCCW))
        return bCW >= bCCW ? "cw" : "ccw"
    }
    let b0 = redTopBias(img)
    let b180 = redTopBias(rotate(img, "180"))
    return b0 >= b180 ? "0" : "180"
}

// ---------- deskew ----------
// Perspective correction aligns the page with the frame, but the printed ruling
// lines can still sit ~1 degree off (paper curl / an imprecise corner). Measure
// the residual shear with the projection-profile method and rotate it out.
/// 生成「墨迹掩膜」：过暗的像素和饱和的红色都记为 1。
///
/// 为什么把红色也算进来：稿纸的格线是红的，纠偏时要让格线参与投影峰值，
/// 否则纯手写的行结构太弱、测不准。但若只取红色，黑白文档就完全失效了，
/// 所以两者取并集。
func inkMask(_ img: CIImage, _ sw: Int) -> (mask: [UInt8], w: Int, h: Int) {
    let sh = max(1, Int(Double(sw) * img.extent.height / img.extent.width))
    let buf = smallBitmap(img, sw, sh)
    var mask = [UInt8](repeating: 0, count: sw * sh)
    for i in 0..<(sw * sh) {
        let r = Int(buf[i * 4]), g = Int(buf[i * 4 + 1]), b = Int(buf[i * 4 + 2])
        let luma = (299 * r + 587 * g + 114 * b) / 1000
        // dark ink, or saturated red (the printed ruling lines / heading)
        if luma < 190 || (r - max(g, b) > 30 && r > 100) { mask[i] = 1 }
    }
    return (mask, sw, sh)
}

// shear m that makes the page's lines horizontal: y' = y - (x-cx)*m
/// 给一个剪切量 m 打分。
///
/// 做法：把每个墨迹像素按 y' = y − (x−cx)·m 重新投射到「行」上，
/// 统计每行的墨迹数量，返回这个数列的方差。
///
/// 方差越大 = 墨迹越集中在少数几行 = 文字行越接近水平 = m 越接近真实倾斜。
/// 这是经典的「投影轮廓法 (projection profile)」倾斜检测。
///
/// 用**剪切**近似代替真正的**旋转**：小角度下两者几乎等价，
/// 但剪切不需要重采样，可以在一秒内试几百个候选角度。
func shearScore(_ m: Double, _ mask: [UInt8], _ sw: Int, _ sh: Int) -> Double {
    var bins = [Double](repeating: 0, count: sh * 3)
    let cx = Double(sw) / 2
    for y in 0..<sh {
        let row = y * sw
        for x in 0..<sw where mask[row + x] == 1 {
            let yy = Int(Double(y) - (Double(x) - cx) * m) + sh
            if yy >= 0 && yy < bins.count { bins[yy] += 1 }
        }
    }
    let n = Double(bins.count)
    let mean = bins.reduce(0, +) / n
    return bins.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / n
}

// returns (shear m, variance improvement over no-deskew)
/// 在 ±3° 范围内搜索让投影方差最大的剪切量，并做两轮细化。
///
/// - Returns: (最佳剪切量, 相比不纠偏时的方差提升倍数)
///
/// 提升倍数用来判断「这张图到底有没有规则的行结构」：
/// 若只有 1.0x 出头，说明它压根没有成行的内容（比如一张风景照），
/// 硬转只会转坏，此时 deskew 会主动放弃。
func estimateShear(_ img: CIImage) -> (Double, Double) {
    let (mask, sw, sh) = inkMask(img, 420)
    let v0 = shearScore(0, mask, sw, sh)
    var bestM = 0.0, bestV = v0
    var m = -0.05
    while m <= 0.05 {
        let v = shearScore(m, mask, sw, sh)
        if v > bestV { bestV = v; bestM = m }
        m += 0.002
    }
    for _ in 0..<2 {                                  // refine
        let lo = bestM - 0.002, hi = bestM + 0.002
        var mm = lo
        while mm <= hi {
            let v = shearScore(mm, mask, sw, sh)
            if v > bestV { bestV = v; bestM = mm }
            mm += 0.0004
        }
    }
    return (bestM, v0 > 0 ? bestV / v0 : 1)
}

/// 绕画面中心做任意角度旋转，四角用白色填充。
///
/// 与 rotate() 的分工：rotate() 只做 90° 整数倍（纯像素重排，无损）；
/// 本函数做任意角度，必然要重采样，所以只用于小幅纠偏。
func rotateAboutCenter(_ img: CIImage, _ angle: Double) -> CIImage {
    let e = img.extent
    let c = CGPoint(x: e.midX, y: e.midY)
    var t = CGAffineTransform(translationX: c.x, y: c.y)
    t = t.rotated(by: CGFloat(angle))
    t = t.translatedBy(x: -c.x, y: -c.y)
    let rot = img.transformed(by: t)
    let bg = CIImage(color: .white).cropped(to: rot.extent)
    return normalizeOrigin(rot.composited(over: bg).cropped(to: e))
}

// largest axis-aligned rectangle inscribed in a WxH rect rotated by `angle`
/// 求「旋转后的矩形内部能放下的最大正置矩形」。
///
/// ── 为什么需要 ──
///   任意角度旋转后，画面四角会露出白三角。直接按原宽高裁剪会切掉内容，
///   所以必须算内接矩形。由「内接矩形的四个角必须都落在旋转后的矩形内」
///   这组约束联立求解，得到：
///       w = (W·cosθ − H·sinθ) / cos2θ
///       h = (H·cosθ − W·sinθ) / cos2θ
///
/// 角度过大导致公式退化（cos2θ → 0）时，直接返回原尺寸，避免裁出空图。
func inscribedRect(_ size: CGSize, _ angle: Double) -> CGRect {
    let a = abs(angle), c = cos(a), s = sin(a), c2 = cos(2 * a)
    guard c2 > 0.05 else { return CGRect(origin: .zero, size: size) }
    let w = (size.width * c - size.height * s) / c2
    let h = (size.height * c - size.width * s) / c2
    guard w > size.width * 0.5, h > size.height * 0.5 else { return CGRect(origin: .zero, size: size) }
    return CGRect(x: (size.width - w) / 2, y: (size.height - h) / 2, width: w, height: h)
}

// deskew, then crop away the white wedges the rotation leaves behind
/// 自动纠偏：把印刷格线的残余倾斜转掉。
///
/// ── 为什么需要 ──
///   即使做过透视校正，纸张自身的翘曲仍会让格线偏 1° 左右。
///   实测某张照片残余 −1.025°，纠偏后 0.000°。
///
/// ── 流程 ──
///   估计剪切量 → 旋转 → **自检**（重新测量残余，若变差就回退原图）
///   → 按内接矩形裁掉旋转产生的白角
///
/// ── 两个保守设计（宁可不做，也不要乱做）──
///   · |角度| < 0.05° 不动手，避免无意义的两次重采样
///   · 投影方差提升不足 minGain 倍不动手，避免对没有规则行的图片乱转
func deskew(_ img: CIImage, minGain: Double) -> CIImage {
    let (m, gain) = estimateShear(img)
    let deg = atan(m) * 180 / .pi
    log(String(format: "deskew: shear=%.4f (%.2f deg) variance gain=%.2fx", m, deg, gain))
    if abs(deg) < 0.05 || gain < minGain {
        log("deskew: tilt negligible or no clear line structure, skipping")
        return img
    }
    var rotated = rotateAboutCenter(img, atan(m))
    let (m2, _) = estimateShear(rotated)              // self-check
    log(String(format: "deskew: residual after correction %.4f", m2))
    if abs(m2) > abs(m) {
        log(String(format: "deskew: correction made it worse (%.4f), trying opposite sign", m2))
        let alt = rotateAboutCenter(img, -atan(m))
        let (m3, _) = estimateShear(alt)
        if abs(m3) > abs(m) { log("deskew: no improvement, keeping original"); return img }
        rotated = alt
    }
    let r = inscribedRect(img.extent.size, atan(m))
    return normalizeOrigin(rotated.cropped(to: r))
}

/// 生成「扫描件质感」—— 全文件对观感影响最大的函数。
///
/// ── ① 去阴影 / 增白（flatten，可用 --noflatten 关闭）──
///   做法：**原图 ÷ 它自己的大幅高斯模糊灰度图**。
///
///   原理：阴影和光照梯度是**低频**的（缓慢变化），笔迹是**高频**的。
///   模糊之后剩下的就是「光照分量」，用原图一除就把它消掉了，只留下
///   「反射率」。纸张在任何位置都变成纯白，而笔迹和红格线因为是高频而
///   原样保留 —— **颜色也不丢**，因为除的是灰度图，色彩比例不变。
///
///   ★ CIDivideBlendMode 的方向是「背景图(inputBackgroundImage) = 原图」。
///     写反了整页会发白、笔迹淡到看不见。这个坑是渲染出来肉眼对比才发现的：
///     数值上两种方向的平均亮度几乎一样（0.953 vs 0.950），骗过了最初的判断。
///
/// ── ② 降噪 ── 压掉手机传感器噪点，让纸面真正干净
/// ── ③ 色阶（CIToneCurve）── 把 0.90 以上的亮度全部拉到纯白，同时保住暗部笔迹
/// ── ④ 对比 / 饱和 / 亮度微调 ──
/// ── ⑤ 锐化（CIUnsharpMask）── 补偿前面多次重采样造成的软化
///
/// - Parameter bw:      true 输出灰度高对比版本（红格线会变灰，一般不用）
/// - Parameter flatten: false 跳过第 ① 步（照片光照本就很均匀时用）
func scanLook(_ img: CIImage, bw: Bool, flatten: Bool) -> CIImage {
    var x = img
    if flatten {
        // flatten page illumination: divide the original by a heavily blurred
        // grayscale copy of itself (CIDivideBlendMode = background / source)
        let r = max(x.extent.width, x.extent.height) * 0.05
        let gray = x.applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 0.0])
        let bg = gray.applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: r])
            .cropped(to: x.extent)
        x = bg.applyingFilter("CIDivideBlendMode", parameters: [kCIInputBackgroundImageKey: x])
            .cropped(to: img.extent)
    }
    // denoise the paper so blank areas go truly flat, before we stretch levels
    x = x.applyingFilter("CINoiseReduction", parameters: [
        "inputNoiseLevel": 0.03, "inputSharpness": 0.5,
    ]).cropped(to: img.extent)
    // levels: push paper to pure white, keep strokes
    x = x.applyingFilter("CIToneCurve", parameters: [
        "inputPoint0": CIVector(x: 0.00, y: 0.00),
        "inputPoint1": CIVector(x: 0.55, y: 0.62),
        "inputPoint2": CIVector(x: 0.80, y: 0.93),
        "inputPoint3": CIVector(x: 0.90, y: 1.00),
        "inputPoint4": CIVector(x: 1.00, y: 1.00),
    ])
    if bw {
        x = x.applyingFilter("CIColorControls", parameters: [
            kCIInputSaturationKey: 0.0, kCIInputContrastKey: 1.35, kCIInputBrightnessKey: 0.02,
        ])
    } else {
        x = x.applyingFilter("CIColorControls", parameters: [
            kCIInputSaturationKey: 0.95, kCIInputContrastKey: 1.12, kCIInputBrightnessKey: 0.02,
        ])
    }
    x = x.applyingFilter("CIUnsharpMask", parameters: [kCIInputRadiusKey: 2.0, kCIInputIntensityKey: 0.6])
    return x.cropped(to: img.extent)
}

/// 输出 A4 单页 PDF：图片按比例居中缩放，四周留 marginMM 毫米白边。
///
/// 用 CGPDFContext 直接绘制，不经任何第三方 PDF 库。
/// 页面尺寸按毫米换算成点（1 毫米 = 72/25.4 点）。
func savePDF(_ image: CIImage, _ path: String, mmW: CGFloat, mmH: CGFloat, marginMM: CGFloat) {
    let img = normalizeOrigin(image)
    guard let cg = ctx.createCGImage(img, from: img.extent) else { log("createCGImage failed"); exit(2) }
    let box = CGRect(x: 0, y: 0, width: mmW * 72 / 25.4, height: mmH * 72 / 25.4)
    var mediaBox = box
    guard let consumer = CGDataConsumer(url: URL(fileURLWithPath: path) as CFURL),
          let pdf = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
        log("cannot write \(path)"); exit(2)
    }
    pdf.beginPDFPage(nil)
    pdf.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    pdf.fill(box)
    let m = marginMM * 72 / 25.4
    let avail = CGSize(width: box.width - 2 * m, height: box.height - 2 * m)
    let s = min(avail.width / CGFloat(cg.width), avail.height / CGFloat(cg.height))
    let w = CGFloat(cg.width) * s, h = CGFloat(cg.height) * s
    pdf.interpolationQuality = .high
    pdf.draw(cg, in: CGRect(x: (box.width - w) / 2, y: (box.height - h) / 2, width: w, height: h))
    pdf.endPDFPage()
    pdf.closePDF()
    log("wrote \(path)  A4 \(Int(mmW))x\(Int(mmH))mm")
}

/// 四边内缩若干像素。
/// 透视校正后画面最外圈常残留 1~2 像素的桌面颜色（检测到的四角可能略微
/// 超出纸张），内缩掉即可，内容损失可以忽略。
func inset(_ img: CIImage, _ px: CGFloat) -> CIImage {
    guard px > 0 else { return img }
    return normalizeOrigin(img.cropped(to: img.extent.insetBy(dx: px, dy: px)))
}

// ---------- main ----------
struct Opts {
    var rot = "auto"
    var insetPx: CGFloat = 8
    var bw = false
    var flatten = true
    var doDeskew = true
    // 默认 1.02。曾经用 1.15，但那会导致真实的轻微倾斜被误判成「没有行结构」
    // 而跳过纠偏（实测三个样本里有两个 gain 只有 1.03~1.04）。
    // 纠偏本身带自检（纠正后重测，变差就回退），所以放宽是安全的。
    var minGain = 1.02
}

/// 处理单张照片的完整流程。批处理模式会反复调用它。
///
/// ★ 关键：Vision 的模型、CoreImage 的上下文在**进程内是复用**的。
///   所以「一个进程处理 N 张」远比「N 个进程各处理 1 张」快 ——
///   这正是 batch 模式存在的全部理由（实测 3 张 17 秒 vs 单张 30 秒）。
func runOne(_ inPath: String, out: String?, pdf: String?, _ o: Opts) -> Bool {
    guard let cg = loadCG(inPath) else { log("cannot load \(inPath)"); return false }
    log("input: \(inPath)  \(cg.width)x\(cg.height)")
    let base = CIImage(cgImage: cg)
    let corrected = perspectiveCorrect(base, cg)
    var page = corrected
    var rot = o.rot
    if rot == "auto" { rot = autoOrient(page) }
    log("rotation: \(rot)")
    page = rotate(page, rot)
    if o.doDeskew { page = deskew(page, minGain: o.minGain) }
    page = inset(page, o.insetPx)
    let look = scanLook(page, bw: o.bw, flatten: o.flatten)
    if let out { savePNG(look, out, dpi: 300) }
    if let pdf { savePDF(look, pdf, mmW: 210, mmH: 297, marginMM: 4) }
    return true
}

/// 解析命令行参数。
/// 以 `--` 开头的是选项；第一个非选项参数视为输出路径（PNG），
/// PDF 路径由 `--pdf` 单独指定。
func parseOpts(_ a: [String], from: Int) -> (Opts, String?, String?)? {
    var o = Opts()
    var out: String? = nil, pdf: String? = nil
    var i = from
    while i < a.count {
        switch a[i] {
        case "--bw":        o.bw = true
        case "--noflatten": o.flatten = false
        case "--nodeskew":  o.doDeskew = false
        case "--rot":       i += 1; if i < a.count { o.rot = a[i] }
        case "--pdf":       i += 1; if i < a.count { pdf = a[i] }
        case "--inset":     i += 1; if i < a.count { o.insetPx = CGFloat(Double(a[i]) ?? 8) }
        case "--skewgain":  i += 1; if i < a.count { o.minGain = Double(a[i]) ?? 1.02 }
        default:
            if out == nil { out = a[i] } else { log("unexpected arg \(a[i])"); return nil }
        }
        i += 1
    }
    return (o, out, pdf)
}

let a = CommandLine.arguments
guard a.count >= 3 else {
    log("""
    usage:
      scan process <in> <out.png> [--pdf out.pdf] [--rot auto|cw|ccw|0|180] [--bw] [--noflatten] [--nodeskew] [--inset N]
      scan batch   <outdir> <in1> <in2> ...   # 一次加载模型，批量处理（快得多）
    """)
    exit(1)
}
let mode = a[1]

if mode == "process" {
    guard let (o, out, pdf) = parseOpts(a, from: 3) else { exit(1) }
    if out == nil && pdf == nil { log("nothing to write: pass an output .png and/or --pdf <file>"); exit(1) }
    exit(runOne(a[2], out: out, pdf: pdf, o) ? 0 : 1)
}

if mode == "batch" {
    // batch <outdir> <files...> [--rot ...] [--bw] ...
    guard a.count >= 4 else { log("usage: scan batch <outdir> <in1> <in2> ..."); exit(1) }
    let outdir = a[2]
    var files: [String] = []
    var o = Opts()
    var i = 3
    while i < a.count {
        switch a[i] {
        case "--bw":        o.bw = true
        case "--noflatten": o.flatten = false
        case "--nodeskew":  o.doDeskew = false
        case "--rot":       i += 1; if i < a.count { o.rot = a[i] }
        case "--inset":     i += 1; if i < a.count { o.insetPx = CGFloat(Double(a[i]) ?? 8) }
        case "--skewgain":  i += 1; if i < a.count { o.minGain = Double(a[i]) ?? 1.02 }
        default:            files.append(a[i])
        }
        i += 1
    }
    var ok = 0, bad = 0
    for f in files {
        let base = (f as NSString).lastPathComponent
        let stem = (base as NSString).deletingPathExtension
        var png = "\(outdir)/\(stem)-扫描件.png"
        var pdf = "\(outdir)/\(stem)-扫描件.pdf"
        var n = 2
        while FileManager.default.fileExists(atPath: png) || FileManager.default.fileExists(atPath: pdf) {
            png = "\(outdir)/\(stem)-扫描件(\(n)).png"
            pdf = "\(outdir)/\(stem)-扫描件(\(n)).pdf"
            n += 1
        }
        mark("start \(stem)")
        if runOne(f, out: png, pdf: pdf, o) { ok += 1; mark("done  \(stem)") } else { bad += 1 }
    }
    print("BATCH|\(ok)|\(bad)")
    exit(bad == 0 ? 0 : 1)
}

// ---- 调试模式（需要单张输入）----
guard let cg = loadCG(a[2]) else { log("cannot load \(a[2])"); exit(1) }
let base = CIImage(cgImage: cg)
let corrected = perspectiveCorrect(base, cg)
log("corrected: \(Int(corrected.extent.width))x\(Int(corrected.extent.height))")


if mode == "correct" {
    savePNG(corrected, a[3], dpi: 300)
    exit(0)
}

log("unknown mode \(mode)")
exit(1)
