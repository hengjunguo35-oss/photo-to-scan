-- ============================================================================
--  applet.applescript — Photo2Scan.app 的图形外壳
-- ============================================================================
--
--  这个脚本本身不处理任何图像，它只做三件事：
--    1. 接收用户操作（双击图标 / 把照片拖到图标上）
--    2. 拼出一条命令去调用同 bundle 内的 scan-worker.sh
--    3. 把结果显示成对话框，并提供「打开输出文件夹」按钮
--
--  真正的图像处理全部在 Swift 引擎（src/scan.swift）里完成。
--
--  ── 两种入口（AppleScript applet 的两个事件处理器）──
--    on run   用户双击图标时触发 → 处理「待扫描」文件夹里已有的图片
--    on open  用户把文件拖到图标上时触发 → 处理这些被拖入的文件
--  注意：直接运行 Contents/MacOS/droplet 并传命令行参数，走的是 on run，
--  不会触发 on open（拖拽是 Apple Event，不是命令行参数）。
--  这一点在自动化测试时很容易踩错。
--
--  ── 环境变量（同时用于测试与自定义）──
--    SCAN_WORKDIR   自定义工作文件夹，默认 ~/Documents/扫描仪
--    SCAN_NODIALOG  设为非空则不弹窗，把结果写入 <WORKDIR>/.last-result.txt
--                   这样脚本/CI 就能headless地调用整个 App
--
--  ── 为什么要用 (path to me) ──
--    App 可能被拖到任何位置（/Applications、桌面、U 盘…），
--    用「本 bundle 自身的位置」去定位内置的 scan-worker.sh，
--    才能保证整个 .app 可以自由移动。
-- ============================================================================


-- 工作文件夹：优先取环境变量，否则用 ~/Documents/扫描仪
on workDir()
	try
		set e to system attribute "SCAN_WORKDIR"
		if e is not "" and e is not missing value then return e
	end try
	return (POSIX path of (path to home folder)) & "Documents/扫描仪"
end workDir


-- 本 bundle 内嵌工具的位置。path to me = 这个 .app 自己
on resDir()
	return (POSIX path of (path to me)) & "Contents/Resources/scan-tool"
end resDir


-- 是否处于「无界面模式」（自动化调用时用）
on silent()
	return (system attribute "SCAN_NODIALOG") is not ""
end silent


-- ── 入口一：双击 ──
-- 传空文件列表，worker 会转而扫描「待扫描」文件夹
on run
	my doScan({})
end run


-- ── 入口二：拖拽 ──
-- theFiles 是 macOS 传进来的一组 alias，转成 POSIX 路径后交给 doScan
on open theFiles
	set paths to {}
	repeat with f in theFiles
		set end of paths to (POSIX path of f)
	end repeat
	my doScan(paths)
end open


-- 统一的错误出口：无界面模式写文件，否则弹窗
on fail(msg, wd)
	if my silent() then
		do shell script "printf '%s' " & quoted form of ("ERROR|" & msg) & " > " & ¬
			quoted form of (wd & "/.last-result.txt")
		return
	end if
	display dialog msg buttons {"好"} default button 1 with icon stop with title "扫描仪"
end fail


-- ── 核心调度 ──
on doScan(paths)
	set wd to my workDir()
	-- 拼命令。quoted form of 是关键：路径里常有空格和中文，
	-- 不加引号会被 shell 拆成多个参数。
	set cmd to "SCAN_WORKDIR=" & quoted form of wd & " " & ¬
		quoted form of (my resDir() & "/scan-worker.sh")
	repeat with p in paths
		set cmd to cmd & " " & quoted form of p
	end repeat

	try
		set out to do shell script cmd
	on error errMsg
		my fail("扫描出错：" & errMsg, wd)
		return
	end try

	-- 无界面模式：把 worker 的原始返回值写进文件后直接结束。
	-- 这条路径让整个 App 可以被脚本或 CI 调用，不需要人去点弹窗。
	if my silent() then
		do shell script "printf '%s' " & quoted form of out & " > " & ¬
			quoted form of (wd & "/.last-result.txt")
		return
	end if

	-- 解析 worker 的返回值：RESULT|<成功>|<失败>|<输出目录>|<待扫描>|<失败文件名>
	set AppleScript's text item delimiters to "|"
	set parts to text items of out
	set AppleScript's text item delimiters to ""
	if (count of parts) < 6 then
		display dialog "返回结果异常，请查看日志文件夹：" & return & wd & "/日志" ¬
			buttons {"好"} default button 1 with icon caution with title "扫描仪"
		return
	end if

	set okc to item 2 of parts        -- 成功数
	set badc to item 3 of parts       -- 失败数
	set outdir to item 4 of parts     -- 输出目录
	set inbox to item 5 of parts      -- 待扫描目录
	set failed to item 6 of parts     -- 失败的文件名列表

	-- 情况一：两边都是 0，说明「待扫描」是空的，引导用户去放照片
	if okc is "0" and badc is "0" then
		set r to display dialog "「待扫描」文件夹里没有图片。" & return & return & ¬
			"把照片拖到「扫描仪」图标上，或放进这个文件夹后再次打开本程序：" & return & ¬
			inbox buttons {"打开文件夹", "好"} default button 1 with title "扫描仪"
		if button returned of r is "打开文件夹" then do shell script "open " & quoted form of inbox
		return
	end if

	-- 情况二：正常处理完了，报告结果
	set msg to "完成：成功 " & okc & " 个"
	if badc is not "0" then
		set msg to msg & "，失败 " & badc & " 个" & return & "失败：" & failed
	end if
	set msg to msg & return & return & "输出文件夹：" & return & outdir

	set r to display dialog msg buttons {"打开输出文件夹", "好"} default button 1 with title "扫描仪"
	if button returned of r is "打开输出文件夹" then do shell script "open " & quoted form of outdir
end doScan
