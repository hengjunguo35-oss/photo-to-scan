# Photo2Scan — Technical Documentation

> Applies to: the initial release of `photo-to-scan` · Platform: macOS 13+ · Author: hengjunguo35-oss

> 🌐 **About this English version**
> This document was translated from the Chinese original jointly by the author
> (**hengjunguo35-oss**) and **DeepSeek Harness**.
>
> If you come across awkward phrasing or outright mistakes, please forgive them — and do
> feel free to open an issue or send a pull request. Contributions to both the code and
> the documentation are warmly welcome.
>
> The Chinese version is the authoritative one: **[技术文档.md](技术文档.md)**.

---

## Where this came from

11 p.m. Homework is due tomorrow. The assignment: **submit a scanned copy of your handwritten work.**

So I went looking for a tool. WPS popped up a paywall. The free alternatives either watermarked
the output or — **wanted to upload my homework to someone else's server**. A homework assignment
with my real name on it.

Here I am, a computer science student, and a scan function has me stuck. **Fine. I'll write one.**

I figured it would take an afternoon. It took three days. The trap was in the last step: almost
every scanning tool finishes with **binarisation**, and the red ruling lines on Chinese manuscript
paper sit so close to paper-white in luminance that they get erased outright.

So the program has exactly one iron rule — **never binarise**.

It solved my problem. I hope it solves yours.

---

## 1. What this program actually does

**Input**: a phone photo of a paper document. The frame usually contains a wooden desk, a keyboard,
shadows and perspective skew.

**Output**: a PNG and an A4 PDF that look like they came out of a scanner. The page is squared up
and flattened, the background is pure white, the ruling lines are level.

**What it deliberately does *not* do** — these are hard constraints, not "not implemented yet":

| Not done | Why |
|---|---|
| No OCR, no re-flowing of text | Handwriting can't be recognised reliably; re-flowing destroys the original |
| No generative "repair" | AI-filled pixels would **fabricate handwriting** — that isn't a scan |
| No binarisation | See above — it erases the ruling lines on manuscript paper |

**The core requirement: handwriting and printed ruling lines must be preserved as raw pixels.**

---

## 2. How it works

### 2.1 The core idea: a 3×3 matrix solves "cluttered background"

In a photo, the sheet of paper is a **skewed quadrilateral**.

The program only has to do one thing: derive the **homography** — a 3×3 matrix that maps the four
corners of the page exactly onto the four corners of a rectangle, with every other pixel
interpolated by the same matrix.

```
Skewed page in the photo              After correction
   ┌──────────┐                    ┌────────────┐
  /           \                     │            │
 /    page     \      ──warp──▶     │    page    │
 \             /                    │            │
  \           /                     │            │
   └──────────┘                     └────────────┘
 desk & keyboard around it           pixels outside the page fall outside the frame
```

**The key insight**: the desk and keyboard are **not detected and erased — they simply never make
it into the frame.** Find the four corners of the page and the clutter problem disappears on its
own. That is far simpler and far more reliable than foreground/background segmentation.

### 2.2 The full pipeline

The entry point is `runOne()`, which calls seven stages in order:

#### ① Find the page corners — `frameQuad()` / `detectQuad()`

Two routes; the fast one is tried first.

**Fast path `frameQuad()`**: find the **printed coloured border** on the sheet (the red frame on
Chinese manuscript paper) directly in the pixels. The test is "vivid red" —
`r > 100 && r - max(g,b) > 55`. It has to be that strict, because the brown of a wooden desk is
**also saturated** — it just doesn't have such a dominant red channel.

Then:
1. Use four extreme points (min/max of `x+y` and `x-y`) as initial corner estimates
2. For each edge, take the points falling inside that edge's band and fit a line by
   **total least squares (PCA)**
3. Intersect adjacent edges to get exact corners

> ⚠️ There's a counter-intuitive trap here: **you cannot use the naive "leftmost red pixel per
> row" approach.** Once a rectangle is rotated, the leftmost point traces a **V shape** along two
> edges, and a single straight line simply won't fit it. This mistake actually happened and cost
> a lot of time.

**Slow fallback `detectQuad()`**: Apple Vision's `VNDetectDocumentSegmentationRequest` (a CoreML
model shipped with macOS). It is very robust for "white paper on a cluttered background", but it
**reloads the model on every process launch** — measured at 20–30 s. So it is only used when the
fast path fails.

> ★ **The coverage check — the single most important safety design in this project**
>
> After computing the corners, the fast path samples every edge and checks the red-pixel coverage.
> **If any edge is below 0.70, it gives up.**
>
> One real example: right edge coverage `1.00`, left edge `0.58`, **top and bottom edges only
> `0.08`** — under that lighting the short edges of the sheet were practically invisible.
>
> Fitting to such a broken edge would **silently crop the body text**, and the user would never
> notice. Falling back to a 30-second Vision call is far preferable to that risk.

#### ② Perspective correction — `perspectiveCorrect()`

Calls `CIPerspectiveCorrection`, which solves the homography internally and resamples every output
pixel by inverse mapping with bilinear interpolation.

#### ③ Auto orientation — `autoOrient()`

The page in the photo may be rotated 90° / 180° / 270°. Two steps:

**Step one: is the text horizontal or vertical?** — `lineAxisRatio()`

The principle: horizontal text makes the "how much ink is on each row" sequence fluctuate sharply
(rows containing text have lots of ink, the gaps between lines have little), so the **row-projection
variance is large**. Vertical text is the opposite.

The measured signal is very clean: vertical `0.469` vs horizontal `2.344` — a factor of five, no
ambiguity.

**Step two: which way is up?** — `redTopBias()`

The projection method can only tell the axis, **not which end is the top** (rotate 180° and the
text rows are still horizontal). The solution: manuscript paper, official documents and exam papers
all have a large red heading near the top. Count whether there are more red pixels in the upper half
or the lower half, and the orientation is settled.

#### ④ Auto deskew — `deskew()`

**Why it's needed**: even after perspective correction, the **warping of the paper itself** still
leaves the printed ruling lines about 1° off. One measured sample had a residual of **−1.025°** —
a deviation you can barely see with your eyes, but can measure with maths.

**Method**: the classic **projection-profile** technique.
- For a given shear `m`, reproject every ink pixel onto "rows" using `y' = y − (x−cx)·m`
- Count the ink per row and compute the **variance** of that sequence
- Larger variance = ink concentrated in fewer rows = the ruling lines are more level
- Search `m` over ±3° for the maximum, then refine in two passes

> **Shear** is used as an approximation of true **rotation**: at small angles the two are nearly
> equivalent, but shear needs no resampling, so hundreds of candidate angles can be tried in under
> a second.

**Two conservative guards** (better to do nothing than to do the wrong thing):
- `|angle| < 0.05°` → do nothing, avoiding two pointless resamples
- Variance improvement below 1.02× → do nothing; it means the image genuinely has no regular line
  structure and rotating it would only make things worse
  (this value was originally 1.15, but that proved too strict in practice — two of three test
  samples had a real tilt that was misjudged as "no structure" and skipped)

**After deskewing**, the white corners introduced by rotation are cropped away using the
**largest inscribed rectangle**:

```
w = (W·cosθ − H·sinθ) / cos2θ
h = (H·cosθ − W·sinθ) / cos2θ
```

(Derived by solving the constraint that all four corners of the inscribed rectangle must lie
inside the rotated rectangle.)

**Measured result: −1.025° → 0.000°.**

#### ⑤ Producing the "scanned document look" — `scanLook()`

This is the function with the largest effect on how the output looks. At its heart is
**shadow removal / whitening**:

> **Method: divide the image by a heavily blurred grayscale copy of itself.**

**Principle**: shadows and illumination gradients are **low-frequency** (slowly varying); strokes
are **high-frequency**. After blurring, what remains is the "illumination component". Dividing it
out removes it, leaving only "reflectance".

The result: the paper becomes pure white everywhere, while strokes and red ruling lines are
**preserved exactly** because they are high-frequency — and **the colour survives too**, because
what is being divided is a grayscale image, so the colour ratios are unchanged.

The paper is pushed to pure white while the ruling lines stay red. This step is the entire source
of the "scanned document" look.

| Step | Filter | Purpose |
|---|---|---|
| Denoise | `CINoiseReduction` | Suppress phone sensor noise so the paper is genuinely clean |
| Levels | `CIToneCurve` | Pull everything above 0.90 to pure white while keeping dark strokes |
| Fine-tune | `CIColorControls` | Contrast / saturation / brightness |
| Sharpen | `CIUnsharpMask` | Compensate for the softening caused by repeated resampling |

#### ⑥ Edge inset — `inset()`

After perspective correction the outermost ring of pixels often still carries 1–2 pixels of desk
colour. Insetting by a few pixels removes it at negligible cost.

#### ⑦ Output — `savePNG()` / `savePDF()`

300 dpi PNG and a single-page A4 PDF (drawn directly with `CGPDFContext`, no third-party library).

### 2.3 The one constraint that runs through everything

**Stay in RGB space throughout. Never binarise.**

The red ruling lines on Chinese manuscript paper sit very close to paper-white in luminance. Any
adaptive thresholding (Sauvola / Wolf / Otsu / unpaper / textcleaner) will **erase the ruling lines
outright**; converting to grayscale will **destroy their red colour**.

That constraint rules out the vast majority of off-the-shelf solutions — and it is precisely why
this program exists.

---

## 3. Technologies used

### 3.1 Language and toolchain

| Technology | Purpose |
|---|---|
| **Swift 5.9** | All engine logic |
| **swiftc** | Compiles to a standalone executable (`-O`) |
| **lipo** | Merges x86_64 + arm64 into a universal binary |
| **AppleScript** | The app's drag-and-drop / double-click shell (compiled with `osacompile`) |
| **Bash** | Working-directory management and batch dispatch |
| **Python 3 + Pillow** | Output quality measurement tool |

### 3.2 Apple frameworks (all system-provided — zero third-party dependencies)

| Framework | Capabilities used |
|---|---|
| **Vision** | `VNDetectDocumentSegmentationRequest` to find the page; `VNDetectRectanglesRequest` as a fallback |
| **CoreImage** | Perspective correction, Gaussian blur, divide blend, tone curve, noise reduction, unsharp mask |
| **CoreGraphics** | Image I/O, bitmap analysis, PDF generation |
| **ImageIO** | Decoding HEIC / TIFF / WebP |
| **Foundation** | Files, strings, time |

### 3.3 Algorithms implemented from scratch (no library used)

| Algorithm | Location | Purpose |
|---|---|---|
| Coloured-border detection + PCA edge fitting | `frameQuad()` | Fast-path page detection |
| Projection-profile skew detection | `estimateShear()` / `shearScore()` | The core of deskewing |
| Row/column projection-variance ratio | `lineAxisRatio()` | Deciding the text axis |
| Red heading localisation | `redTopBias()` | Resolving the 180° ambiguity |
| Largest inscribed rectangle | `inscribedRect()` | Cropping the rotation corners |
| Illumination flattening (division) | `scanLook()` | Shadow removal and whitening |

### 3.4 Why not OpenCV / Python

- **Zero dependencies**: the user doesn't need Homebrew, Python or OpenCV — none of them.
  Double-click and it runs.
- **Leverages a system-provided model**: Vision's document segmentation model is a CoreML model
  trained by Apple. Its quality is far beyond a hastily written OpenCV contour detector.
- **Performance**: CoreImage filters run on the GPU; pixel-by-pixel Python would be far slower.

> The trade-off: this program **runs on macOS only**. A Windows version would need the imaging layer
> rewritten in Python + Pillow, and there is no equivalent page-detection model available.

---

## 4. Setting up the environment

### 4.1 System requirements

| Item | Requirement |
|---|---|
| OS | **macOS 13.0 or later** (uses the Vision document-segmentation API, which requires macOS 12+) |
| Build tools | Xcode or Command Line Tools |
| Runtime dependencies | **None.** System frameworks only |

Install the build tools:

```bash
xcode-select --install
```

### 4.2 Building the engine

```bash
cd photo-to-scan
swiftc -O src/scan.swift -o scan
```

This produces a standalone executable named `scan`.

> ⚠️ **An extremely well-hidden trap: build intermediates must live on a pure-ASCII path.**
>
> If you point `CLANG_MODULE_CACHE_PATH` or `TMPDIR` at a path **containing non-ASCII characters**,
> the Swift 5.9 compiler crashes outright with `Illegal instruction: 4` (exit 132) — and gives
> **no meaningful error message at all**.
>
> This was hit for real: after the project directory was renamed to 「扫描仪-App源码」, every build
> died instantly. It took a long time to work out that it had nothing to do with the architecture
> or the code — it was purely the non-ASCII path.

### 4.3 Packaging into a double-clickable app

```bash
./app/build-app.sh            # builds a universal binary (x86_64 + arm64)
./app/build-app.sh --native   # host architecture only, faster
```

`build-app.sh` automatically places build intermediates on a pure-ASCII path under `/tmp`,
sidestepping the trap above.

The result is a **self-contained** `photo-to-scan.app` — the Swift engine is embedded in the bundle,
so it can be copied to another Mac and will run there **without Xcode and without this source tree**.

### 4.4 What to do when Gatekeeper blocks the first launch

If the `.app` arrived via AirDrop, a cloud drive or a download, it carries a quarantine flag and
macOS will refuse to launch it. Two solutions:

```bash
# Option 1: right-click the app → Open (only needed once)

# Option 2: strip the flag directly
xattr -dr com.apple.quarantine /path/to/photo-to-scan.app
```

---

## 5. Usage

### 5.1 Command line

```bash
# Single photo
./scan process photo.jpg output.png --pdf output.pdf

# Batch (strongly recommended)
./scan batch output_dir/ photo1.jpg photo2.jpg photo3.jpg
```

### 5.2 The app

After launching `photo-to-scan.app` there are two ways to use it:

| Action | Effect |
|---|---|
| **Double-click the icon** | Processes every image in `~/Documents/扫描仪/待扫描/` |
| **Drag photos onto the icon** | Processes that batch immediately |

Where the output goes:

```
~/Documents/扫描仪/
├── 待扫描/        Drop original photos here
├── 扫描件输出/    Finished output: a PNG + an A4 PDF per photo
├── 已扫描/        Processed originals are archived here automatically
└── 日志/          Full log of each run — look here when something goes wrong
```

> The folder names are Chinese. Set `SCAN_WORKDIR` to relocate the working folder.

### 5.3 Options

| Option | Default | Description |
|---|---|---|
| `--rot auto\|cw\|ccw\|0\|180` | `auto` | Force a rotation. Use when automatic detection fails |
| `--nodeskew` | off | Disable automatic deskew |
| `--skewgain N` | `1.02` | Deskew threshold: only act if the projection variance improves by at least N× |
| `--noflatten` | off | Disable shadow removal / whitening (use when lighting is already even) |
| `--bw` | off | Output a grayscale high-contrast version (ruling lines turn grey; rarely wanted) |
| `--inset N` | `8` | Inset N pixels on all sides, removing residual desk colour at the edges |

### 5.4 Environment variables

| Variable | Effect |
|---|---|
| `SCAN_WORKDIR` | Move the working folder elsewhere (default `~/Documents/扫描仪`) |
| `SCAN_NODIALOG` | If non-empty, suppress dialogs and write the result to `<WORKDIR>/.last-result.txt` (for scripts / CI) |

---

## 6. Performance

### 6.1 Where the bottleneck is

**Vision's document-segmentation model reloads on every process launch.** Instrumented measurement
(single photo):

```
[  0.21s] loaded
[ 25.19s] perspective corrected   ← everything is stuck here
[ 25.46s] rotated
[ 25.84s] deskewed                ← my own deskew algorithm takes only 0.28 s
[ 25.88s] scan look done
```

| Mode | Time (2017 Intel Core m3) |
|---|---|
| Single `process` | ~30 s (29 s of which is model loading) |
| 3 photos, `batch` | **17 s** (model loaded once; ~1 s per additional photo) |

**So use `batch` even for two photos.**

### 6.2 Two optimisation attempts that didn't work (recorded so nobody repeats them)

| Attempt | Result |
|---|---|
| Downsample input to 900 px / 600 px before detection | ❌ No change (still 25 s) — the bottleneck is **model loading**, not inference |
| Suspected the sandbox was blocking CoreML cache writes | ❌ Still 19.4 s outside the sandbox, and no cache directory was created — the machine is simply slow |

**What did work**: removing two unnecessary OCR calls in favour of pure-pixel line-axis detection
(57 s → 26 s per photo), and reusing the model across a batch.

---

## 7. Troubleshooting

| Symptom | Cause and fix |
|---|---|
| Wrong orientation | Force it with `--rot cw` or `--rot ccw` |
| Ruling lines still tilted | Check the `deskew:` line in the log. If `variance gain < 1.02`, there genuinely is no line structure |
| Paper looks grey or shadowy | Check you didn't accidentally pass `--noflatten` (it should be on by default) |
| **Body text was cropped** | Page detection drifted. Check whether `quad source:` in the log says `printed frame` or `Vision document segmentation` |
| A single photo is very slow | Normal (model loading). Use `batch` |
| Build fails with `Illegal instruction: 4` | The module cache path contains non-ASCII characters — see §4.2 |
| Double-clicking the app does nothing | Check the latest run record under `~/Documents/扫描仪/日志/` |

---

## 8. Quality verification

```bash
python3 tools/measure.py output.png
```

### Three reliable metrics

| Metric | Pass condition | Meaning |
|---|---|---|
| **Residual tilt** | close to `0.000 deg` | Whether the ruling lines are level |
| **Edge outlier ratio** | `< 0.02` | Whether desk colour remains at the edges |
| **Paper mode** | `255` | Whether the paper is pure white (also check the overall luminance distribution) |

### ⚠️ A metric that lies

The "blank band luma" reported by `measure.py` is **not trustworthy**: the horizontal band it samples
cuts across the red ruling lines, contaminating the mean. Worse, **the more level the ruling lines
are, the more concentrated the red is inside that band, so the standard deviation goes *up*** — it
looks like things got worse when they actually got better.

To judge whiteness, look at the **mode** and **P95** of the whole-image luminance distribution.

### The last step must be visual

**Don't ship on measurements alone.** Confirm with your own eyes that the ruling lines are level,
the title hasn't been cropped, and no strokes have been lost.

---

## 9. Known limitations

1. **macOS 13+ only.** A Windows version would require rewriting the imaging layer (Vision has no
   equivalent replacement).
2. **The fast path depends on a printed coloured border on the sheet.** Without one (plain black
   text on white paper) it falls back to the slow Vision path.
3. **Auto orientation depends on a large red area at the top.** For pure black-and-white documents
   without that signal, orientation detection may fail — specify it manually with `--rot`.
4. **Page detection needs contrast between paper and background.** A photo where the page fills the
   entire frame with no background visible may not be detected.
5. **The first single-photo run is slow** (20–30 s of model loading). This is inherent overhead in
   the system framework and cannot be avoided — only amortised through batching. On Apple Silicon it
   is an order of magnitude faster.

---

## 10. Repository layout

```
photo-to-scan/
├── README.md                  Project overview and quick start (Chinese)
├── README.en.md               Project overview and quick start (English)
├── 技术文档.md                 This document (Chinese, authoritative)
├── TECHNICAL.en.md            This document (English)
├── 免责声明.md                  Disclaimer and terms of use (Chinese, authoritative)
├── DISCLAIMER.en.md           Disclaimer and terms of use (English)
├── LICENSE                    MIT + Commons Clause
├── src/
│   └── scan.swift             Engine: all algorithms and the filter pipeline
│                              (single file, annotated function by function)
├── app/
│   ├── applet.applescript     App shell (drag-and-drop / double-click)
│   ├── scan-worker.sh         Working-directory management and batch dispatch
│   ├── build-app.sh           Packages into a .app
│   └── make-release.sh        Produces DMG + ZIP + SHA256 checksums
├── tools/
│   └── measure.py             Objective quality measurement of the output
└── docs/
    └── demo.jpg               Before/after demonstration images
```

### Suggested reading order

To understand this program, reading the code in this order is the least painful route:

1. The **file-header comment** at the top of `src/scan.swift` — build the big picture first
2. `runOne()` — see how the seven stages are wired together
3. `scanLook()` — understand where the "scanned look" comes from (the elegance of the division)
4. `estimateShear()` / `shearScore()` — the deskew algorithm, the most mathematical part
5. `frameQuad()` — pay particular attention to the **coverage check**, and why being slow beats
   cropping incorrectly

---

## Licence

MIT + Commons Clause — see [LICENSE](LICENSE). Resale is prohibited; commercial use requires a
separate licence.
