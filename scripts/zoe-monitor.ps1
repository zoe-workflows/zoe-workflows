#Requires -Version 5.1
<#
.SYNOPSIS
zoe-monitor.ps1 — 与 zoe-monitor.sh **同语义**的 Windows 监控循环（v1.5.2）。

.DESCRIPTION
职责边界（与 .sh 逐条对齐，避免"两个平台两种判断"）：
  * 本脚本只**观察**：读 `task status`（权威当前状态）、`zoe watch`（历史事件），
    以及可选的 `task logs`（Agent 逐条输出了什么）。
  * 它不推进任何任务或组：`watch` 不推进，`group start`/`group resume` 才推进。
  * 终止判断读 `task status`，不读事件历史，也**不读日志**。

与 .sh 的差异只在实现，不在判断：
  * 事件解析用 `ConvertFrom-Json`，因此**不依赖 jq**（Windows 宿主通常没有）；
  * 其余协议完全一致：游标先读后写、事件先落盘再推进游标、日志只展示不判定、
    结束原因 `[stop] reason=`、退出码 0/2/10/11。

退出码（**不因新选项改变**）：
  0  目标全部终态（DONE/CANCELLED），或预算（-MaxRounds / -MaxSeconds）到期
  2  用法/依赖错误（缺 -Project、目标为空、zoe 不可用、参数非法）
  10 剩余目标都需要人工介入（审查/验收/排障），脚本主动停下
  11 `zoe watch` 连续失败达到 -MaxErrors

结束原因：ALL_TERMINAL / BUDGET_EXHAUSTED / HUMAN_REQUIRED / WATCH_ERROR /
DEPENDENCY_ERROR，每次退出打印一行 `[stop] reason=…`，`-StopFile` 时同值写入 JSON。

用法：
  pwsh scripts/zoe-monitor.ps1 -Project demo -Targets "task-a task-b"
  pwsh scripts/zoe-monitor.ps1 -Project demo -TargetsFile targets.txt -Interval 5
  pwsh scripts/zoe-monitor.ps1 -Project demo -Targets "task-a" -MaxRounds 1   # 冒烟
  pwsh scripts/zoe-monitor.ps1 -Project demo -Targets "task-a" -WithLog `
    -MaxSeconds 600 -StopFile .zoe/stop.json

感知延迟 ≈ Interval + 查询耗时；不要对外声称实时。
#>

[CmdletBinding()]
param(
    [string]$Project = "",
    [string]$Targets = "",
    [string]$TargetsFile = "",
    [string]$Events = "./zoe-events.jsonl",
    [string]$CursorFile = "./zoe-cursor.txt",
    [string]$WatchErr = "./zoe-watch.err",
    [int]$Interval = 3,
    [int]$MaxRounds = 0,
    [int]$MaxSeconds = 0,
    [int]$MaxErrors = 5,
    [string]$StopFile = "",
    [switch]$WithLog,
    [int]$LogBytes = 8192,
    [int]$LogLines = 3,
    [switch]$Help
)

$script:Clock = [System.Diagnostics.Stopwatch]::StartNew()
$script:StopEmitted = $false
$script:LogState = ""
$script:LogErrors = 0
$script:WithLog = [bool]$WithLog
$script:Cur = ""
$script:Rounds = 0

function Show-Usage {
    Write-Output @'
Usage: zoe-monitor.ps1 -Project P (-Targets "T1 T2" | -TargetsFile F) [options]

  -Project P          项目 ID（必需；事件过滤与归属校验都用它）
  -Targets "T1 T2"    要监控的任务 ID，空格分隔
  -TargetsFile F      从文件读任务 ID（每行一个，# 开头为注释）
  -Events F           事件落盘路径（默认 ./zoe-events.jsonl）
  -CursorFile F       游标持久化路径（默认 ./zoe-cursor.txt）
  -Interval N         轮间隔秒数（默认 3；即感知延迟）
  -MaxRounds N        跑满 N 轮后正常退出（默认 0=不限；冒烟用 1）
  -MaxSeconds N       预算秒数（单调时钟，与 -MaxRounds 先到者生效；默认 0=不限）
  -MaxErrors N        watch 连续失败上限（默认 5，超过则 exit 11）
  -StopFile F         把结束原因写成 JSON（默认不写）
  -WithLog            每轮追加仍在跑的目标的**新增**可读进展（默认关）
  -LogBytes N         单轮每目标读取窗口字节数（默认 8192；上限 1048576）
  -LogLines N         单轮每目标最多输出行数（默认 3）
  -Help               显示本帮助

环境变量：ZOE_BIN（默认 zoe）、ZOE_MONITOR_SLEEP（覆盖 -Interval）。
退出码：0 全部终态或预算到期 / 2 用法错误 / 10 需人工介入 / 11 监控不可用。
结束原因另见末行 `[stop] reason=…`；-StopFile 时同值写入 JSON。
'@
}

function Get-Elapsed {
    return [int]$script:Clock.Elapsed.TotalSeconds
}

# 结束原因只写一次：无论从哪条路径退出，都有一行可机器判定的 `[stop] reason=`。
function Emit-Stop {
    param([string]$Reason, [bool]$AllTerminal = $false)
    if ($script:StopEmitted) { return }
    $script:StopEmitted = $true
    Write-Output "[stop] reason=$Reason cur=$($script:Cur) rounds=$($script:Rounds) elapsed=$(Get-Elapsed)s"
    if (-not $StopFile) { return }
    $payload = [ordered]@{
        monitor_stop_reason = $Reason
        all_terminal        = $AllTerminal
        next_cursor         = $script:Cur
        rounds              = $script:Rounds
        elapsed_seconds     = (Get-Elapsed)
        # 空候选（candidate_sha == base_sha）单独一份：仍属"等人工验收"，
        # 但"等验收"与"没有内容可验收"要能分开。纯增量键。
        # 早退路径（用法错误）会在初始化之前调用本函数，这里兜住 $null。
        empty_candidates    = @(if ($null -ne $script:EmptyCandidates) { $script:EmptyCandidates } else { @() })
    }
    try {
        $json = ($payload | ConvertTo-Json -Compress)
        [System.IO.File]::WriteAllText($StopFile, "$json`n", $script:Utf8)
    }
    catch {
        Write-Output "[warn] cannot write stop file: $($_.Exception.Message)"
    }
}

function Exit-Monitor {
    param([int]$Code, [string]$Reason, [bool]$AllTerminal = $false)
    Emit-Stop -Reason $Reason -AllTerminal $AllTerminal
    if ($script:LogState -and (Test-Path -LiteralPath $script:LogState)) {
        Remove-Item -LiteralPath $script:LogState -Recurse -Force -ErrorAction SilentlyContinue
    }
    exit $Code
}

# 依赖/用法错误：不是任务失败，但监控本身不可用。
function Stop-Usage {
    param([string]$Message)
    Write-Output "[error] $Message"
    Exit-Monitor -Code 2 -Reason "DEPENDENCY_ERROR"
}

if ($Help) { Show-Usage; exit 0 }

# UTF-8 无 BOM：带 BOM 会让事件文件的首行 JSON 无法被下游解析。
$script:Utf8 = New-Object System.Text.UTF8Encoding($false)

if ($env:ZOE_MONITOR_SLEEP) { $Interval = [int]$env:ZOE_MONITOR_SLEEP }
if (-not $Project) { Stop-Usage "-Project is required" }

# 目标集合：命令行与文件合并，去重并压掉空白（重复 ID 会让计数与 [needs-human] 重复）。
if ($TargetsFile) {
    if (-not (Test-Path -LiteralPath $TargetsFile)) {
        Stop-Usage "targets file not found: $TargetsFile"
    }
    $fromFile = (Get-Content -LiteralPath $TargetsFile) |
        ForEach-Object { ($_ -replace '#.*$', '') } |
        Where-Object { $_.Trim() }
    $Targets = "$Targets $($fromFile -join ' ')"
}
$targetList = @($Targets -split '\s+' | Where-Object { $_ } | Select-Object -Unique)
if ($targetList.Count -eq 0) {
    Stop-Usage "no targets: use -Targets or -TargetsFile"
}

# 参数校验放在依赖检查之后、循环之前：错在启动时比错在第五轮便宜。
if ($MaxRounds -lt 0) { Stop-Usage "-MaxRounds must be a non-negative integer" }
if ($MaxSeconds -lt 0) { Stop-Usage "-MaxSeconds must be a non-negative integer" }
if ($MaxErrors -lt 0) { Stop-Usage "-MaxErrors must be a non-negative integer" }
if ($LogBytes -lt 1 -or $LogBytes -gt 1048576) { Stop-Usage "-LogBytes must be 1..1048576" }
if ($LogLines -lt 1) { Stop-Usage "-LogLines must be at least 1" }

# 定位 zoe：ZOE_BIN 优先，否则 PATH。与 .sh 一样只认可执行文件——
# 源码绑定（ZOE_SRC）需要补 PYTHONPATH，不在本脚本职责内。
$zoeName = if ($env:ZOE_BIN) { $env:ZOE_BIN } else { "zoe" }
$zoeCmd = Get-Command $zoeName -ErrorAction SilentlyContinue
if (-not $zoeCmd) {
    Stop-Usage "zoe not found: $zoeName"
}
$script:ZoeExe = if ($zoeCmd.Path) { $zoeCmd.Path } else { $zoeCmd.Definition }

function Add-EventLines {
    param([string]$Path, [string[]]$Lines)
    if (-not $Lines -or $Lines.Count -eq 0) { return }
    $text = ($Lines -join "`n") + "`n"
    [System.IO.File]::AppendAllText($Path, $text, $script:Utf8)
}

function Write-Cursor {
    param([string]$Path, [string]$Value)
    [System.IO.File]::WriteAllText($Path, "$Value`n", $script:Utf8)
}

function Read-Cursor {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return "" }
    if ((Get-Item -LiteralPath $Path).Length -eq 0) { return "" }
    # 只取第一行：多行（历史追加/手工编辑）拼起来会得到一个"看起来合法"的错游标。
    $first = Get-Content -LiteralPath $Path -TotalCount 1
    if ($null -eq $first) { return "" }
    return ([string]$first).Trim()
}

# 调 zoe：stdout 逐行返回，stderr 写文件（错误诊断要能贴给用户，且不能污染 JSON）。
function Invoke-Zoe {
    param([string[]]$ZoeArgs, [string]$ErrFile = "")
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        if ($ErrFile) {
            $out = & $script:ZoeExe @ZoeArgs 2>$ErrFile
        }
        else {
            $out = & $script:ZoeExe @ZoeArgs 2>$null
        }
        $code = $LASTEXITCODE
        # 归一成"干净的行数组"：`$null` 与单行字符串在 PS 里形状不同，
        # 后面要按下标取末行（meta），形状必须先确定下来。
        $lines = @()
        foreach ($line in @($out)) {
            if ($null -ne $line) { $lines += [string]$line }
        }
        return [pscustomobject]@{ Code = $code; Lines = $lines }
    }
    finally {
        $ErrorActionPreference = $previous
    }
}

# 展示游标只服务"这一轮打印过了没有"：进程内临时目录，退出即丢弃，
# 绝不写进任务状态库或 progress.json（那会制造第二事实源）。
if ($script:WithLog) {
    $script:LogState = Join-Path ([System.IO.Path]::GetTempPath()) ("zoe-log-" + [guid]::NewGuid().ToString("N"))
    try {
        New-Item -ItemType Directory -Path $script:LogState -Force | Out-Null
    }
    catch {
        $script:WithLog = $false
        $script:LogState = ""
        Write-Output "[log-off] cannot create a temp dir for the display cursor"
    }
}

# 追加"新增的"可读进展。$Task=任务  $RunId=current_run_id
#
# 规则（四条都是硬要求）：
#   1. 只展示新增：首次无游标 ⇒ 展示窗口尾部一次，此后只输出新事件；无新事件不补行；
#   2. run 切换 / 日志回绕 ⇒ 丢弃旧游标重新定位（游标无法自证来自哪个 run/日志）；
#   3. 读取失败只记 `[log-error]`，游标不动，不改变退出码，连续 3 次关闭本功能；
#   4. 游标与日志名绑定：本函数固定读 `--log agent`；若将来把日志名参数化，换日志必须
#      丢弃旧游标——cursor 只编码 run/generation/offset，无法自证来自哪个日志文件。
function Emit-Log {
    param([string]$Task, [string]$RunId)

    $curf = Join-Path $script:LogState "$Task.cursor"
    $cur = ""
    if (Test-Path -LiteralPath $curf) {
        $raw = Get-Content -LiteralPath $curf -TotalCount 1 -ErrorAction SilentlyContinue
        if ($null -ne $raw) { $cur = ([string]$raw).Trim() }
    }
    if ($cur -and $RunId -and ($cur.Split(':')[0] -ne $RunId)) { $cur = "" }

    $errFile = Join-Path $script:LogState "err.txt"
    $zoeArgs = @("task", "logs", $Task, "--log", "agent", "--json", "--tail-bytes", "$LogBytes")
    if ($cur) {
        $zoeArgs = @("task", "logs", $Task, "--log", "agent", "--json", "--after", $cur, "--tail-bytes", "$LogBytes")
    }
    $result = Invoke-Zoe -ZoeArgs $zoeArgs -ErrFile $errFile
    $errText = ""
    if (Test-Path -LiteralPath $errFile) {
        $errText = ((Get-Content -LiteralPath $errFile -ErrorAction SilentlyContinue) -join " ")
    }

    # 旧 runtime（不认识 --after）时软兜底关闭：argparse 的退出码是 2，与
    # INPUT_INCOMPLETE 同码，只能看 stderr 才能区分，绝不能把两者混为一谈。
    if ($result.Code -ne 0 -and $errText -match 'unrecognized arguments') {
        $script:WithLog = $false
        Write-Output "[log-off] runtime 不接受 task logs --after：已关闭 -WithLog（其余监控照常）"
        return
    }

    $payload = $null
    if ($result.Code -eq 0 -and $result.Lines.Count -gt 0) {
        try { $payload = ($result.Lines -join "`n") | ConvertFrom-Json } catch { $payload = $null }
    }
    if (-not $payload) {
        $script:LogErrors++
        Write-Output "[log-error] $Task 读取失败（不影响监控与退出码）"
        if ($script:LogErrors -ge 3) {
            $script:WithLog = $false
            Write-Output "[log-off] 日志读取连续失败，已关闭 -WithLog"
        }
        return
    }
    $script:LogErrors = 0

    # 日志被截断/替换：不报错，也不把整份日志当成"新进展"重新播一遍。
    # 丢弃旧游标 ⇒ 下一轮按窗口重新初始化一次（S8-B2 规则 2）。响应里的 reset_cursor
    # （offset 0）不写回去：那会从新文件**开头**开始播，而不是"最近发生了什么"。
    if ($payload.rotated -eq $true) {
        Remove-Item -LiteralPath $curf -Force -ErrorAction SilentlyContinue
        return
    }

    # 只展示"可读进展"：说话（text）与动作（tool）。record/raw 不是"没有输出"，
    # 但它们不构成可读进展，所以不进 `[log]` 行。
    $events = @($payload.events) |
        Where-Object { $_ -and ($_.kind -eq "text" -or $_.kind -eq "tool") } |
        Select-Object -Last $LogLines
    foreach ($event in $events) {
        if ($event.kind -eq "text") {
            Write-Output "[log] $Task 说：$($event.text)"
        }
        else {
            Write-Output "[log] $Task 动：$($event.name) $($event.target)  (过程观察，非成功证据)"
        }
    }

    # 只有解析成功才推进展示游标：读取失败绝不当成"没有新日志"。
    if ($payload.next_cursor) {
        try { Write-Cursor -Path $curf -Value ([string]$payload.next_cursor) } catch { }
    }
}

# 游标：先复用，缺省才初始化。初始化取的是"当前末端"，只在首次运行时发生，
# 所以"第一次启动会跳过启动前的事件"是明确行为，不是缺陷。
$script:Cur = Read-Cursor -Path $CursorFile
if (-not $script:Cur) {
    $init = Invoke-Zoe -ZoeArgs @("watch", "--project", $Project, "--json")
    if ($init.Code -ne 0) {
        Write-Output "[error] watch init failed; 游标未建立"
        Exit-Monitor -Code 2 -Reason "WATCH_ERROR"
    }
    $initMeta = $null
    try { $initMeta = ($init.Lines -join "`n") | ConvertFrom-Json } catch { $initMeta = $null }
    $script:Cur = if ($initMeta) { [string]$initMeta.next_cursor } else { "" }
    if (-not $script:Cur) {
        Stop-Usage "init response has no next_cursor"
    }
    try { Write-Cursor -Path $CursorFile -Value $script:Cur }
    catch {
        Stop-Usage "cannot write cursor file: $($_.Exception.Message)"
    }
    Write-Output "[init] cursor=$($script:Cur) (首次运行：起点为当前末端)"
}

$human = @()
$finished = @()
$errors = 0
# 空候选清单：Emit-Stop 里要读它，所以放 script 作用域（与 .sh 的 EMPTY_CANDIDATES 对应）。
$script:EmptyCandidates = @()

while ($true) {
    $script:Rounds++
    $rounds = $script:Rounds

    # 0) 预算（单调时钟）：与 -MaxRounds 取先到者，退出码仍是 0。
    if ($MaxSeconds -gt 0 -and (Get-Elapsed) -ge $MaxSeconds) {
        Write-Output "[stop] max seconds reached (elapsed=$(Get-Elapsed)s rounds=$rounds cur=$($script:Cur))"
        Exit-Monitor -Code 0 -Reason "BUDGET_EXHAUSTED"
    }

    # 1) 权威状态：终止判断只看这里。
    $alive = 0
    $needHuman = 0
    $phases = @()
    $runs = @()
    $aliveList = @()
    $runOf = @{}
    # 本批静默最长的仍在跑目标（只用于展示，不参与 alive/needHuman/退出码）。
    $quietMax = -1
    $quietTask = ""
    foreach ($t in $targetList) {
        if ($finished -contains $t) { continue }
        # 终止判断必须读**对账之后**的状态：不带 --refresh 时 supervisor 中途死亡的
        # 任务会永远停在 RUNNING，监控耗光预算也报不出"进程没了"。--refresh 失败
        # （旧运行器不认这个开关）时退回只读查询，不因此判失败。与 .sh 同语义。
        $status = Invoke-Zoe -ZoeArgs @("task", "status", $t, "--json", "--refresh")
        if ($status.Code -ne 0) {
            $status = Invoke-Zoe -ZoeArgs @("task", "status", $t, "--json")
        }
        $row = $null
        if ($status.Code -eq 0 -and $status.Lines.Count -gt 0) {
            try { $row = ($status.Lines -join "`n") | ConvertFrom-Json } catch { $row = $null }
        }
        $st = if ($row) { [string]$row.state } else { "" }
        # `INPUT_REQUIRED` 是 block_code，不是 state：只看 state 永远匹不到它。
        $block = if ($row) { [string]$row.block_code } else { "" }
        # phase 与 run 只是**展示**：phase 长时间不变是正常的，"阶段没变"不是卡住。
        $phase = if ($row) { [string]$row.phase } else { "" }
        $runId = if ($row) { [string]$row.current_run_id } else { "" }
        # 零候选判定用：优先运行时的 empty_candidate，老版本没有该字段时
        # 退回比较两个**非空** SHA（两个空 SHA 表示"还没验证"，不能判等）。
        $baseSha = if ($row) { [string]$row.base_sha } else { "" }
        $candSha = if ($row) { [string]$row.candidate_sha } else { "" }
        $emptyFlag = ($row -and $row.empty_candidate -eq $true)
        # 静默秒数（观测事实，不是健康度）：只用于 tick 的展示列。
        $quiet = ""
        if ($row -and $null -ne $row.progress -and $null -ne $row.progress.quiet_seconds) {
            $quiet = [string]$row.progress.quiet_seconds
        }
        # 列表元素用逗号分隔（S8-B1 的格式）：字段之间是空格，宿主按逗号切分即可。
        if ($phase) { $phases += "${t}:${phase}" }
        if ($runId) { $runs += "${t}:${runId}"; $runOf[$t] = $runId }
        if (-not $st) {
            # 读不到就报出来，不能当作"仍在运行"——那会让脚本永远不退出。
            Write-Output "[warn] status unreadable: $t"
            $alive = 1
            continue
        }
        # 用 if/elseif 而不是 switch：`break` 在 switch 与 foreach 混合时的作用域
        # 容易读错，而这里"标记一个目标后继续处理下一个"是硬要求。
        if ($st -eq "DONE" -or $st -eq "CANCELLED") {
            $finished += $t
            Write-Output "[final] $t $st"
        }
        elseif ($st -eq "REVIEW_READY") {
            # 等人工验收：不是终态，也不是"还在跑"。
            $needHuman++
            $isEmpty = $emptyFlag -or ($baseSha -and $candSha -and ($baseSha -eq $candSha))
            if ($human -notcontains $t) {
                $human += $t
                if ($isEmpty) {
                    $script:EmptyCandidates += $t
                    Write-Output "[needs-human] $t REVIEW_READY 但 empty_diff=true（candidate_sha == base_sha）无改动可验收"
                }
                else {
                    Write-Output "[needs-human] $t REVIEW_READY 等人工验收"
                }
            }
        }
        elseif ($st -eq "BLOCKED" -or $st -eq "PAUSED") {
            $needHuman++
            $label = $st
            if ($block -eq "INPUT_REQUIRED") { $label = "$st/INPUT_REQUIRED（等回答）" }
            if ($human -notcontains $t) {
                $human += $t
                Write-Output "[needs-human] $t $label"
            }
        }
        else {
            # 仍在跑：run 已在上面的展示列表里登记过，这里只记"要跟进的目标"。
            $alive = 1
            $aliveList += $t
            # 静默最长者：缺失或非数字**不参与**比较，而不是当成 0。
            $quietInt = 0
            if ($quiet -and [int]::TryParse(($quiet -split '\.')[0], [ref]$quietInt)) {
                if ($quietInt -gt $quietMax) { $quietMax = $quietInt; $quietTask = $t }
            }
        }
    }

    if ($alive -eq 0) {
        if ($needHuman -eq 0) {
            Write-Output "[done] all targets final (rounds=$rounds)"
            Exit-Monitor -Code 0 -Reason "ALL_TERMINAL" -AllTerminal $true
        }
        $names = if ($human.Count) { " " + ($human -join " ") } else { "" }
        Write-Output "[pause] remaining targets need a human:$names"
        Exit-Monitor -Code 10 -Reason "HUMAN_REQUIRED"
    }

    # 2) 检查点：没有事件时也要有一行，否则"仍在监控"无法被验证。
    $humanNames = if ($human.Count) { $human -join " " } else { "none" }
    # 逗号分隔，与 .sh 的 `phases=` / `runs=` 逐字同形（S8-B1 的格式）。
    $phaseText = if ($phases.Count) { $phases -join ',' } else { "none" }
    $runText = if ($runs.Count) { $runs -join ',' } else { "none" }
    # `quiet=` 只回答"谁最久没输出"，不是健康度；读不到时不报 quiet。
    $quietText = if ($quietTask) { "${quietTask}:${quietMax}" } else { "none" }
    Write-Output "[tick] round=$rounds cur=$($script:Cur) alive=$alive need_human=$needHuman human=$humanNames phases=$phaseText runs=$runText quiet=$quietText"

    # 2.5) 可读进展：每个仍在跑的目标，每轮最多一次 CLI 调用 + ≤ -LogBytes 字节。
    if ($script:WithLog) {
        foreach ($t in $aliveList) {
            if (-not $script:WithLog) { break }
            $rid = if ($runOf.ContainsKey($t)) { $runOf[$t] } else { "" }
            Emit-Log -Task $t -RunId $rid
        }
    }

    # 3) 消费事件：先落盘，再推进游标。
    $watch = Invoke-Zoe -ZoeArgs @("watch", "--project", $Project, "--jsonl", "--after", $script:Cur, "--max-events", "200") -ErrFile $WatchErr
    if ($watch.Code -ne 0) {
        $errors++
        $detail = ""
        if (Test-Path -LiteralPath $WatchErr) {
            $detail = ((Get-Content -LiteralPath $WatchErr) -join " ").Trim()
            if ($detail.Length -gt 200) { $detail = $detail.Substring(0, 200) }
        }
        Write-Output "[error] watch failed (${errors}/${MaxErrors}): $detail"
        if ($errors -ge $MaxErrors) {
            Write-Output "[abort] watch unusable (cur=$($script:Cur)); 修可达性后从游标文件续跑"
            Exit-Monitor -Code 11 -Reason "WATCH_ERROR"
        }
        Start-Sleep -Seconds $Interval
        continue
    }

    $lines = @($watch.Lines)
    $meta = $null
    if ($lines.Count -gt 0) {
        $last = [string]$lines[$lines.Count - 1]
        try { $meta = $last | ConvertFrom-Json } catch { $meta = $null }
    }
    $nxt = if ($meta) { [string]$meta.next_cursor } else { "" }
    if (-not $nxt) {
        # meta 行缺失/不可解析：这一页不能算消费成功，游标保持不动。
        $errors++
        Write-Output "[error] meta line missing or unparsable (${errors}/${MaxErrors})"
        if ($errors -ge $MaxErrors) {
            Write-Output "[abort] cannot read cursor from watch output (cur=$($script:Cur)); 从游标文件续跑"
            Exit-Monitor -Code 11 -Reason "WATCH_ERROR"
        }
        Start-Sleep -Seconds $Interval
        continue
    }

    # 末行是 meta（心跳/游标），丢掉；其余是事件。
    if ($lines.Count -ge 2) {
        try {
            Add-EventLines -Path $Events -Lines @($lines[0..($lines.Count - 2)] | ForEach-Object { [string]$_ })
        }
        catch {
            # 事件落盘失败时游标不动：宁可重放也不丢。
            $errors++
            Write-Output "[error] cannot append events (${errors}/${MaxErrors}): $($_.Exception.Message)"
            if ($errors -ge $MaxErrors) { Exit-Monitor -Code 11 -Reason "WATCH_ERROR" }
            Start-Sleep -Seconds $Interval
            continue
        }
    }
    $script:Cur = $nxt
    try { Write-Cursor -Path $CursorFile -Value $script:Cur }
    catch {
        Stop-Usage "cannot write cursor file: $($_.Exception.Message)"
    }
    $errors = 0

    if ($MaxRounds -gt 0 -and $rounds -ge $MaxRounds) {
        Write-Output "[stop] max rounds reached (rounds=$rounds cur=$($script:Cur))"
        Exit-Monitor -Code 0 -Reason "BUDGET_EXHAUSTED"
    }

    Start-Sleep -Seconds $Interval
}
