#requires -Version 5.1
<#
  内存占用查看：按软件分组显示每个程序（连同它启动的子进程、AI 后台小工具）
  向系统“预订”的内存（提交大小）和实际占用，勾选后可以一键关闭。

  用法：运行 launch.vbs（create-shortcut.ps1 可以在桌面建快捷方式）。
  个人配置：local-config.json（不进仓库），格式见 local-config.example.json。
  测试参数：-List 打印分组；-Snapshot <png> 截图后退出；-SelfTest 验证关闭逻辑；-UiTest <log> 端到端测试。
#>
param(
    [string]$Snapshot,
    [switch]$List,
    [switch]$SelfTest,
    [string]$UiTest,
    [switch]$Collapsed   # 只配合 -Snapshot：截收起状态的图
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms, System.Drawing
Add-Type @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
public static class MemMonNative {
    [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
    // 给输入框加灰色提示文字（EM_SETCUEBANNER）
    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    public static extern IntPtr SendMessage(IntPtr hWnd, int msg, IntPtr wParam, string lParam);

    [DllImport("ntdll.dll")]
    static extern int NtQuerySystemInformation(int infoClass, IntPtr buffer, int length, out int returnLength);

    // 每个进程的专用工作集（任务管理器“内存”一列的口径），PID → 字节。
    // 一次系统调用读完全部进程；读 SYSTEM_PROCESS_INFORMATION，只支持 64 位，失败返回 null。
    public static Dictionary<int, long> GetPrivateWorkingSets() {
        if (IntPtr.Size != 8) return null;
        int size = 1 << 20;
        IntPtr buf = IntPtr.Zero;
        try {
            while (true) {
                buf = Marshal.AllocHGlobal(size);
                int needed;
                int status = NtQuerySystemInformation(5, buf, size, out needed);   // SystemProcessInformation
                if (status == unchecked((int)0xC0000004)) {                         // 缓冲区不够大
                    Marshal.FreeHGlobal(buf); buf = IntPtr.Zero;
                    size = Math.Max(size * 2, needed + 65536);
                    continue;
                }
                if (status != 0) return null;
                break;
            }
            var result = new Dictionary<int, long>();
            long offset = 0;
            while (true) {
                IntPtr entry = new IntPtr(buf.ToInt64() + offset);
                int next = Marshal.ReadInt32(entry, 0);
                long privateWs = Marshal.ReadInt64(entry, 8);                     // WorkingSetPrivateSize
                int pid = (int)Marshal.ReadIntPtr(entry, 80).ToInt64();           // UniqueProcessId
                result[pid] = privateWs;
                if (next == 0) break;
                offset += next;
            }
            return result;
        } catch {
            return null;
        } finally {
            if (buf != IntPtr.Zero) Marshal.FreeHGlobal(buf);
        }
    }
}
'@

# ---------------------------------------------------------------- 配置

# AI 后台小工具开了超过这么多小时，就当作旧会话留下的，标橙色，也可以单独一键关掉
$StaleHours = 12

# 个人配置放在脚本旁边的 local-config.json 里（不进仓库），格式见 local-config.example.json：
#   importantServices：你自己的后台服务（隧道、自动重连脚本等），可以关，但关之前会额外提醒
#   customPurposes：给特定进程起名字，比如你自己的 MCP 服务，这样它不会被当成 AI 后台小工具
# pattern 是正则表达式，拿去匹配进程的命令行和程序路径。
$ImportantServices = @()
$CustomPurposes = @()
$LocalConfigPath = Join-Path $PSScriptRoot 'local-config.json'
if (Test-Path -LiteralPath $LocalConfigPath) {
    try {
        $localConfig = Get-Content -LiteralPath $LocalConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $ImportantServices = @($localConfig.importantServices | Where-Object { $_.pattern -and $_.name } |
            ForEach-Object { @{ Pattern = $_.pattern; Name = $_.name } })
        $CustomPurposes = @($localConfig.customPurposes | Where-Object { $_.pattern -and $_.purpose } |
            ForEach-Object { @{ Pattern = $_.pattern; Purpose = $_.purpose } })
    } catch {
        Write-Warning "local-config.json 读取失败，先按没有个人配置运行：$($_.Exception.Message)"
    }
}

$FriendlyNames = @{
    'chrome.exe' = 'Google Chrome'; 'msedge.exe' = 'Microsoft Edge'; 'claude.exe' = 'Claude'
    'chatgpt.exe' = 'ChatGPT'; 'codex.exe' = 'Codex'; 'wps.exe' = 'WPS Office'; 'notion.exe' = 'Notion'
    'termius.exe' = 'Termius'; 'explorer.exe' = 'Windows 资源管理器'; 'magpie.exe' = 'Magpie'
    'doubao.exe' = '豆包'; 'steam.exe' = 'Steam'; 'spotify.exe' = 'Spotify'; 'weixin.exe' = '微信'
    'wechat.exe' = '微信'; 'qq.exe' = 'QQ'; 'pycharm64.exe' = 'PyCharm'; 'code.exe' = 'VS Code'
    'wpscloudsvr.exe' = 'WPS 云服务'; 'sqlservr.exe' = 'SQL Server 数据库'; 'nvcontainer.exe' = 'NVIDIA 后台服务'
    'clash-verge-service.exe' = 'Clash Verge 服务'; 'mchose hub.exe' = 'MCHOSE HUB（键鼠驱动）'
}

# 读不到路径时（多为系统账户运行的服务），按名字判断是不是 Windows 自带的
$WindowsCoreNames = @('system', 'registry', 'memory compression', 'secure system', 'smss.exe', 'csrss.exe', 'wininit.exe',
    'services.exe', 'lsass.exe', 'lsaiso.exe', 'svchost.exe', 'winlogon.exe', 'fontdrvhost.exe', 'dwm.exe', 'spoolsv.exe',
    'msmpeng.exe', 'nissrv.exe', 'securityhealthservice.exe', 'searchindexer.exe', 'wmiprvse.exe', 'dllhost.exe',
    'audiodg.exe', 'wudfhost.exe', 'sgrmbroker.exe', 'mpdefendercoreservice.exe', 'wlanext.exe', 'conhost.exe')

$AppWarnings = @{
    'claude.exe' = 'Claude 关闭后，正在进行的对话会中断。'
    'codex.exe' = 'Codex 关闭后，正在进行的任务会中断。'
    'chatgpt.exe' = 'ChatGPT 关闭后，正在进行的对话会中断。'
    'wps.exe' = 'WPS 里没保存的文档可能会丢失。'
}

# 父进程是这些时，就把当前进程当作一个“软件”的起点
$BoundaryNames = @('explorer.exe', 'services.exe', 'svchost.exe', 'wininit.exe', 'winlogon.exe', 'userinit.exe',
    'sihost.exe', 'smss.exe', 'csrss.exe', 'system', 'system idle process', 'taskhostw.exe', 'wmiprvse.exe')
$ScriptHosts = @('python.exe', 'pythonw.exe', 'node.exe', 'powershell.exe', 'pwsh.exe', 'cmd.exe', 'wscript.exe',
    'cscript.exe', 'java.exe', 'javaw.exe', 'bun.exe')
$HelperNames = @('node.exe', 'python.exe', 'pythonw.exe', 'java.exe', 'javaw.exe', 'cmd.exe', 'conhost.exe',
    'powershell.exe', 'pwsh.exe', 'bun.exe', 'uv.exe', 'uvx.exe', 'deno.exe')
# C:\Windows 下但属于用户自己开的程序，不算系统
$WindowsUserTools = @('cmd.exe', 'powershell.exe', 'conhost.exe', 'wscript.exe', 'cscript.exe', 'notepad.exe', 'mspaint.exe')
$SystemRoot = $env:SystemRoot.TrimEnd('\') + '\'

# ---------------------------------------------------------------- 数据

$script:DescCache = @{}
function Get-ExeDescription([string]$path) {
    if (-not $path) { return $null }
    if (-not $script:DescCache.ContainsKey($path)) {
        $desc = $null
        try {
            $vi = [Diagnostics.FileVersionInfo]::GetVersionInfo($path)
            $desc = if ($vi.FileDescription) { $vi.FileDescription.Trim() } elseif ($vi.ProductName) { $vi.ProductName.Trim() } else { $null }
        } catch {}
        $script:DescCache[$path] = $desc
    }
    $script:DescCache[$path]
}

function Get-ScriptPath([string]$commandLine) {
    $m = [regex]::Match("$commandLine", '([A-Za-z]:\\[^"*?<>|]+?\.(?:pyw?|m?js|cjs|ps1|bat|cmd|vbs|jar))(?=["\s]|$)', 'IgnoreCase')
    if ($m.Success) { $m.Groups[1].Value } else { $null }
}

function Get-HostLabel([string]$name) {
    switch -Regex ($name) {
        '^pythonw?\.exe$' { return 'Python' }
        '^node\.exe$' { return 'Node.js' }
        '^(powershell|pwsh)\.exe$' { return 'PowerShell' }
        '^cmd\.exe$' { return '命令行' }
        '^[wc]script\.exe$' { return '脚本' }
        '^javaw?\.exe$' { return 'Java' }
        '^bun\.exe$' { return 'Bun' }
    }
    $name
}

function Get-Purpose($p, [bool]$isRoot) {
    $n = "$($p.Name)".ToLower(); $c = "$($p.CommandLine)"
    foreach ($cp in $CustomPurposes) {
        if ("$c $($p.ExecutablePath)" -match $cp.Pattern) { return $cp.Purpose }
    }
    switch -Regex ($n) {
        '^node\.exe$' {
            if ($c -match 'playwright') { return 'playwright 浏览器工具（AI 后台小工具）' }
            if ($c -match 'rea\.mjs|rea-agents') { return 'REA 逆向工具（AI 后台小工具）' }
            if ($c -match 'deepseek-ai\\dsh') { return 'DeepSeek Harness 服务' }
            if ($c -match 'mcp') { return 'MCP 工具（AI 后台小工具）' }
            $s = Get-ScriptPath $c
            if ($s) { return "Node 脚本：$([IO.Path]::GetFileName($s))" }
            return 'Node.js 程序'
        }
        '^javaw?\.exe$' {
            if ($c -match 'jadx|rea-andr') { return 'REA 安卓反编译（AI 后台小工具）' }
            return 'Java 程序'
        }
        '^(pythonw?|powershell|pwsh)\.exe$' {
            $s = Get-ScriptPath $c
            if ($s) { return "$(Get-HostLabel $n) 脚本：$([IO.Path]::GetFileName($s))" }
            return "$(Get-HostLabel $n) 命令行"
        }
        '^cmd\.exe$' {
            if ($c -match 'npx|npm|node') { return 'AI 小工具的启动外壳（cmd）' }
            $s = Get-ScriptPath $c
            if ($s) { return "批处理：$([IO.Path]::GetFileName($s))" }
            return '命令行（cmd）'
        }
        '^conhost\.exe$' { return '控制台宿主（命令行的配套进程）' }
        '^msedgewebview2\.exe$' { return '内嵌网页（WebView2）' }
    }
    if ($c -match '--type=renderer') { if ($c -match '--extension-process') { return '浏览器扩展' }; return '网页 / 界面渲染' }
    if ($c -match '--type=gpu-process') { return 'GPU 加速' }
    if ($c -match '--type=utility') {
        if ($c -match 'network') { return '网络服务' }
        if ($c -match 'audio') { return '音频服务' }
        if ($c -match 'storage') { return '存储服务' }
        return '辅助进程'
    }
    if ($c -match '--type=crashpad-handler') { return '崩溃报告' }
    if ($c -match '--type=') { return '辅助进程' }
    if ($isRoot) { return '主程序' }
    $d = Get-ExeDescription $p.ExecutablePath
    if ($d) { $d } else { $p.Name }
}

function Format-Age($start) {
    if (-not $start) { return '' }
    $span = (Get-Date) - $start
    if ($span.TotalDays -ge 1) { return '{0} 天 {1} 小时' -f [int][math]::Floor($span.TotalDays), $span.Hours }
    if ($span.TotalHours -ge 1) { return '{0} 小时 {1} 分' -f [int][math]::Floor($span.TotalHours), $span.Minutes }
    '{0} 分钟' -f [int][math]::Max(1, [math]::Floor($span.TotalMinutes))
}

function Get-MemorySnapshot {
    $os = Get-CimInstance Win32_OperatingSystem
    $procs = @(Get-CimInstance Win32_Process -Property ProcessId, ParentProcessId, Name, CommandLine, ExecutablePath,
        CreationDate, SessionId, PrivatePageCount, WorkingSetSize)
    $byId = @{}
    foreach ($p in $procs) { $byId[[int]$p.ProcessId] = $p }

    # “实际占用”用专用工作集：工作集会把多个进程共享的内存重复计算，加起来比物理内存还多。
    # 读不到时退回工作集。
    $privateWs = [MemMonNative]::GetPrivateWorkingSets()
    $wsOf = @{}
    foreach ($p in $procs) {
        $id = [int]$p.ProcessId
        $wsOf[$id] = if ($privateWs -and $privateWs.ContainsKey($id)) { [double]$privateWs[$id] } else { [double]$p.WorkingSetSize }
    }

    # 有效的父子关系：父进程存在，且比子进程先启动（防止 PID 被复用）
    $parentOf = @{}
    $children = @{}
    foreach ($p in $procs) {
        $id = [int]$p.ProcessId
        $parent = $byId[[int]$p.ParentProcessId]
        if (-not $parent -or $parent.ProcessId -eq $p.ProcessId) { continue }
        if ($p.CreationDate -and $parent.CreationDate -and $parent.CreationDate -gt $p.CreationDate) { continue }
        $parentOf[$id] = $parent
        if (-not $children.ContainsKey([int]$parent.ProcessId)) { $children[[int]$parent.ProcessId] = New-Object System.Collections.Generic.List[int] }
        $children[[int]$parent.ProcessId].Add($id)
    }

    $selfKey = if ($PSCommandPath) { "script:$($PSCommandPath.ToLower())" } else { '' }
    $groups = [ordered]@{}
    $groupOfRoot = @{}
    foreach ($p in $procs) {
        $cur = $p
        for ($i = 0; $i -lt 64; $i++) {
            $parent = $parentOf[[int]$cur.ProcessId]
            if (-not $parent -or $BoundaryNames -contains "$($parent.Name)".ToLower()) { break }
            $cur = $parent
        }
        $root = $cur
        $rootName = "$($root.Name)".ToLower()

        $key = $null
        $script = $null
        if ($ScriptHosts -contains $rootName) { $script = Get-ScriptPath $root.CommandLine }
        if ($script) { $key = "script:$($script.ToLower())" }
        else { $key = 'exe:' + "$(if ($root.ExecutablePath) { $root.ExecutablePath } else { $root.Name })".ToLower() }

        if (-not $groups.Contains($key)) {
            $important = $null
            foreach ($s in $ImportantServices) {
                if ("$($root.CommandLine) $($root.ExecutablePath)" -match $s.Pattern) { $important = $s.Name; break }
            }
            $exe = "$($root.ExecutablePath)"
            $isWindowsExe = if ($exe) { $exe.StartsWith($SystemRoot, [StringComparison]::OrdinalIgnoreCase) -and $WindowsUserTools -notcontains $rootName }
                else { $WindowsCoreNames -contains $rootName }
            $kind = if ($key -eq $selfKey) { '本工具' }
                elseif ([int]$root.ProcessId -le 4 -or $rootName -eq 'explorer.exe' -or ($isWindowsExe -and -not $important)) { '系统' }
                elseif ([int]$root.SessionId -eq 0 -or -not $exe) { '系统服务' }
                elseif ($important) { '你的后台服务' }
                elseif ($parentOf[[int]$root.ProcessId] -and "$($parentOf[[int]$root.ProcessId].Name)".ToLower() -eq 'svchost.exe') { '后台程序' }
                else { '应用' }

            $label = if ($key -eq $selfKey) { '内存占用查看（本工具）' }
                elseif ($important) { $important }
                elseif ($script) { "$(Get-HostLabel $rootName)：$([IO.Path]::GetFileName($script))（$(Split-Path (Split-Path $script -Parent) -Leaf)）" }
                elseif ($FriendlyNames.ContainsKey($rootName)) { $FriendlyNames[$rootName] }
                else {
                    $d = Get-ExeDescription $root.ExecutablePath
                    if ($d -and $d -notmatch 'Windows® Operating System' -and $d.Length -le 40) { $d -replace '\.exe$', '' } else { $root.Name -replace '\.exe$', '' }
                }

            $groups[$key] = [pscustomobject]@{
                Key = $key; Label = $label; Kind = $kind; RootName = $rootName; ExePath = $root.ExecutablePath
                Protected = ($kind -in @('系统', '系统服务', '本工具'))
                Roots = New-Object System.Collections.Generic.List[int]
                Procs = New-Object System.Collections.Generic.List[object]
                Commit = [double]0; Ws = [double]0; HelperCount = 0; HelperCommit = [double]0; Start = $null
            }
        }
        $g = $groups[$key]
        if ([int]$root.ProcessId -eq [int]$p.ProcessId) { $g.Roots.Add([int]$p.ProcessId) }
        $g.Procs.Add($p)
        $g.Commit += [double]$p.PrivatePageCount
        $g.Ws += $wsOf[[int]$p.ProcessId]
        if ([int]$root.ProcessId -ne [int]$p.ProcessId -and $HelperNames -contains "$($p.Name)".ToLower()) {
            $g.HelperCount++; $g.HelperCommit += [double]$p.PrivatePageCount
        }
        if ($p.CreationDate -and (-not $g.Start -or $p.CreationDate -lt $g.Start)) { $g.Start = $p.CreationDate }
    }

    # 每组内按进程树排好顺序，记下缩进层级
    foreach ($g in $groups.Values) {
        $inGroup = @{}
        foreach ($p in $g.Procs) { $inGroup[[int]$p.ProcessId] = $p }
        $ordered = New-Object System.Collections.Generic.List[object]
        $visit = $null
        $visit = {
            param($id, $depth)
            $p = $inGroup[$id]
            $ordered.Add([pscustomobject]@{
                Pid = $id; Name = $p.Name; Depth = $depth; Purpose = (Get-Purpose $p ($depth -eq 0))
                Commit = [double]$p.PrivatePageCount; Ws = $wsOf[$id]; Start = $p.CreationDate
                Path = $p.ExecutablePath; CommandLine = $p.CommandLine
            })
            if ($children.ContainsKey($id)) {
                foreach ($c in $children[$id]) { if ($inGroup.ContainsKey($c)) { & $visit $c ($depth + 1) } }
            }
        }
        foreach ($r in ($g.Roots | Sort-Object { $inGroup[$_].CreationDate })) { & $visit $r 0 }
        $g | Add-Member -NotePropertyName Rows -NotePropertyValue $ordered
    }

    # 每个软件名下的 AI 后台小工具，以及其中开了很久的那部分；表格、按钮、顶部汇总都用这里的结果
    $staleBefore = (Get-Date).AddHours(-$StaleHours)
    foreach ($g in $groups.Values) {
        $ai = if ($g.Protected) { @() } else { Get-AiToolTargets $children $g }
        $stale = if ($ai.Count) { Get-AiToolTargets $children $g $staleBefore } else { @() }
        $g | Add-Member -NotePropertyName AiTargets -NotePropertyValue $ai
        $g | Add-Member -NotePropertyName AiCommit -NotePropertyValue (($ai | Measure-Object Commit -Sum).Sum + 0)
        $g | Add-Member -NotePropertyName AiStaleTargets -NotePropertyValue $stale
    }

    $totals = Get-MemTotals $os
    [pscustomobject]@{
        Groups = @($groups.Values | Sort-Object Commit -Descending)
        Children = $children
        CommitUsed = $totals.CommitUsed; CommitLimit = $totals.CommitLimit
        PhysUsed = $totals.PhysUsed; PhysTotal = $totals.PhysTotal
        PrivateWs = [bool]$privateWs
        Taken = Get-Date
    }
}

# 只读四个总数，很快，顶部数字每 3 秒用它刷新一次
function Get-MemTotals($os) {
    if (-not $os) {
        $os = Get-CimInstance Win32_OperatingSystem -Property TotalVirtualMemorySize, FreeVirtualMemory, TotalVisibleMemorySize, FreePhysicalMemory
    }
    [pscustomobject]@{
        CommitUsed = ($os.TotalVirtualMemorySize - $os.FreeVirtualMemory) * 1KB
        CommitLimit = $os.TotalVirtualMemorySize * 1KB
        PhysUsed = ($os.TotalVisibleMemorySize - $os.FreePhysicalMemory) * 1KB
        PhysTotal = $os.TotalVisibleMemorySize * 1KB
    }
}

function Get-Descendants($children, [int]$id) {
    $result = New-Object System.Collections.Generic.List[int]
    $queue = New-Object System.Collections.Generic.Queue[int]
    $queue.Enqueue($id)
    while ($queue.Count) {
        $cur = $queue.Dequeue()
        $result.Add($cur)
        if ($children.ContainsKey($cur)) { foreach ($c in $children[$cur]) { $queue.Enqueue($c) } }
    }
    $result
}

# 一个软件名下明确属于 AI 后台小工具的进程（连同它们的子进程），不含软件本体和它自己的组件。
# 给了 $olderThan 时，只算在那之前启动的小工具。
function Get-AiToolTargets($children, $g, $olderThan) {
    $ids = New-Object System.Collections.Generic.HashSet[int]
    foreach ($r in $g.Rows) {
        if ($r.Depth -eq 0 -or $r.Purpose -notlike '*（AI 后台小工具）') { continue }
        if ($olderThan -and (-not $r.Start -or $r.Start -ge $olderThan)) { continue }
        foreach ($d in (Get-Descendants $children $r.Pid)) { [void]$ids.Add($d) }
    }
    @($g.Rows | Where-Object { $ids.Contains([int]$_.Pid) })
}

# 结束进程：有窗口的先请它自己关（最多等 3 秒），之后强制结束。
# $targets 是快照里的进程行（Pid / Name / Start / Commit / Depth），会先核对 PID 没被别的进程复用。
function Stop-Targets($targets) {
    $live = New-Object System.Collections.Generic.List[object]
    $failed = New-Object System.Collections.Generic.List[string]
    foreach ($t in ($targets | Sort-Object Depth)) {
        if ([int]$t.Pid -eq $PID) { continue }
        try { $p = [Diagnostics.Process]::GetProcessById([int]$t.Pid) } catch { continue }
        try {
            if ($t.Start -and [math]::Abs(($p.StartTime - $t.Start).TotalSeconds) -gt 2) { continue }
        } catch { $failed.Add("$($t.Name)（PID $($t.Pid)，权限不足）"); continue }
        $live.Add([pscustomobject]@{ T = $t; P = $p })
    }

    $windowed = @($live | Where-Object { try { $_.P.MainWindowHandle -ne [IntPtr]::Zero } catch { $false } })
    foreach ($w in $windowed) { try { [void]$w.P.CloseMainWindow() } catch {} }
    if ($windowed.Count) {
        $deadline = (Get-Date).AddSeconds(3)
        while ((Get-Date) -lt $deadline) {
            $open = @($windowed | Where-Object { try { -not $_.P.HasExited } catch { $false } })
            if (-not $open.Count) { break }
            Start-Sleep -Milliseconds 200
        }
    }

    $done = 0; $freed = [double]0
    foreach ($l in $live) {
        try {
            if (-not $l.P.HasExited) { $l.P.Kill(); [void]$l.P.WaitForExit(3000) }
            $done++; $freed += $l.T.Commit
        } catch {
            $exited = $false; try { $exited = $l.P.HasExited } catch {}
            if ($exited) { $done++; $freed += $l.T.Commit } else { $failed.Add("$($l.T.Name)（PID $($l.T.Pid)）") }
        }
    }
    [pscustomobject]@{ Done = $done; FreedMB = $freed / 1MB; Failed = $failed }
}

# ---------------------------------------------------------------- 测试入口

if ($List) {
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $snap = Get-MemorySnapshot
    '采集耗时 {0} ms；实际占用口径：{1}' -f $sw.ElapsedMilliseconds, $(if ($snap.PrivateWs) { '专用工作集' } else { '工作集（读不到专用工作集）' })
    '预订 {0:N1} / {1:N1} GB，物理内存 {2:N1} / {3:N1} GB，各软件实际占用合计 {4:N1} GB' -f ($snap.CommitUsed / 1GB), ($snap.CommitLimit / 1GB),
        ($snap.PhysUsed / 1GB), ($snap.PhysTotal / 1GB), (($snap.Groups | Measure-Object Ws -Sum).Sum / 1GB)
    foreach ($g in $snap.Groups | Select-Object -First 40) {
        '{0,7:N0} MB  实际 {1,6:N0} MB  {2,-6} {3,3} 个  AI 小工具 {4,2} 个（旧 {5,2}）{6,6:N0} MB  {7,-12} {8}' -f ($g.Commit / 1MB), ($g.Ws / 1MB), $g.Kind,
            $g.Procs.Count, $g.AiTargets.Count, $g.AiStaleTargets.Count, ($g.AiCommit / 1MB), (Format-Age $g.Start), $g.Label
    }
    foreach ($g in $snap.Groups | Where-Object HelperCount | Select-Object -First 3) {
        $ai = $g.AiTargets
        "== $($g.Label) 的后台小工具（可单独关掉的 AI 小工具 {0} 个，{1:N0} MB）==" -f $ai.Count, (($ai | Measure-Object Commit -Sum).Sum / 1MB)
        $g.Rows | Where-Object { $_.Depth -gt 0 -and $HelperNames -contains "$($_.Name)".ToLower() } | Group-Object Purpose |
            Sort-Object Count -Descending | ForEach-Object { '{0,3} 个 {1,6:N0} MB  {2}' -f $_.Count, (($_.Group | Measure-Object Commit -Sum).Sum / 1MB), $_.Name }
    }
    return
}

if ($SelfTest) {
    $cmd = Start-Process cmd.exe -ArgumentList '/c', 'ping -n 600 127.0.0.1 >nul' -WindowStyle Hidden -PassThru
    Start-Sleep -Seconds 2
    $snap = Get-MemorySnapshot
    $ids = Get-Descendants $snap.Children $cmd.Id
    $rows = foreach ($g in $snap.Groups) { foreach ($r in $g.Rows) { if ($ids -contains $r.Pid) { $r } } }
    "测试进程树：" + (($rows | ForEach-Object { "$($_.Name)($($_.Pid))" }) -join ' → ')
    $res = Stop-Targets $rows
    Start-Sleep -Milliseconds 500
    $left = @($ids | Where-Object { Get-Process -Id $_ -ErrorAction SilentlyContinue })
    "结束 $($res.Done) 个，失败 $($res.Failed.Count) 个，残留 $($left.Count) 个"
    return
}

# ---------------------------------------------------------------- 界面

[void][MemMonNative]::SetProcessDPIAware()
[Windows.Forms.Application]::EnableVisualStyles()

$form = New-Object Windows.Forms.Form
$form.Text = '内存占用查看'
$form.Font = New-Object Drawing.Font('Microsoft YaHei UI', 9)
$form.BackColor = [Drawing.Color]::White
$form.Icon = [Drawing.Icon]::ExtractAssociatedIcon("$env:SystemRoot\System32\Taskmgr.exe")
$gfx = $form.CreateGraphics(); $scale = $gfx.DpiX / 96; $gfx.Dispose()
function S([double]$v) { [int]($v * $scale) }
$form.Size = New-Object Drawing.Size((S 1180), (S 800))
$form.MinimumSize = New-Object Drawing.Size((S 820), (S 520))
$form.StartPosition = 'CenterScreen'

$Orange = [Drawing.Color]::FromArgb(202, 102, 0)

function New-Button([string]$text) {
    $b = New-Object Windows.Forms.Button
    $b.Text = $text; $b.AutoSize = $true; $b.Height = S 32
    $b.Padding = New-Object Windows.Forms.Padding((S 8), 0, (S 8), 0)
    $b.Margin = New-Object Windows.Forms.Padding(0, 0, (S 8), 0)
    $b
}

# 软件图标，按程序路径缓存
$script:IconCache = @{}
$script:BlankIcon = New-Object Drawing.Bitmap((S 16), (S 16))
function Get-AppIcon([string]$path) {
    if (-not $path) { return $script:BlankIcon }
    if (-not $script:IconCache.ContainsKey($path)) {
        $bmp = $script:BlankIcon
        try {
            $ico = [Drawing.Icon]::ExtractAssociatedIcon($path)
            if ($ico) {
                $src = $ico.ToBitmap()
                $bmp = New-Object Drawing.Bitmap((S 16), (S 16))
                $gr = [Drawing.Graphics]::FromImage($bmp)
                $gr.InterpolationMode = 'HighQualityBicubic'
                $gr.DrawImage($src, 0, 0, (S 16), (S 16))
                $gr.Dispose(); $src.Dispose(); $ico.Dispose()
            }
        } catch {}
        $script:IconCache[$path] = $bmp
    }
    $script:IconCache[$path]
}

# ---- 顶部：预订额度、物理内存、AI 后台小工具汇总
$header = New-Object Windows.Forms.TableLayoutPanel
$header.Dock = 'Top'; $header.AutoSize = $true; $header.ColumnCount = 2; $header.RowCount = 4
$header.Padding = New-Object Windows.Forms.Padding((S 12), (S 10), (S 12), (S 4))
$lblCommit = New-Object Windows.Forms.Label
$lblCommit.AutoSize = $true; $lblCommit.Font = New-Object Drawing.Font('Microsoft YaHei UI', 11, [Drawing.FontStyle]::Bold)
$lblCommit.Margin = New-Object Windows.Forms.Padding(0, (S 2), (S 12), 0)
# 自己画的进度条：系统进度条有动画，颜色也不好控制
$bar = New-Object Windows.Forms.Panel
$bar.Width = S 360; $bar.Height = S 20; $bar.Margin = New-Object Windows.Forms.Padding(0, (S 6), 0, 0)
$bar.BackColor = [Drawing.Color]::FromArgb(230, 230, 230)
$barFill = New-Object Windows.Forms.Panel
$barFill.Dock = 'Left'; $barFill.Width = 0
$bar.Controls.Add($barFill)
$lblPhys = New-Object Windows.Forms.Label
$lblPhys.AutoSize = $true; $lblPhys.ForeColor = [Drawing.Color]::DimGray
$lblHint = New-Object Windows.Forms.Label
$lblHint.AutoSize = $true; $lblHint.ForeColor = [Drawing.Color]::DimGray
$lblHint.Text = '“预订”是程序向系统订下的内存（提交大小），快到上限时程序会卡住、闪退或提示内存不足；“实际占用”和任务管理器「内存」一列口径相同。顶部数字每 3 秒自动更新。'
$aiRow = New-Object Windows.Forms.FlowLayoutPanel
$aiRow.AutoSize = $true; $aiRow.WrapContents = $false; $aiRow.Margin = New-Object Windows.Forms.Padding(0, (S 6), 0, 0)
$lblAi = New-Object Windows.Forms.Label
$lblAi.AutoSize = $true; $lblAi.Margin = New-Object Windows.Forms.Padding(0, (S 7), (S 10), 0)
$lblAi.Font = New-Object Drawing.Font('Microsoft YaHei UI', 9, [Drawing.FontStyle]::Bold)
$btnStaleAi = New-Button "只关开了 $StaleHours 小时以上的"
$btnAllAi = New-Button '一键关闭全部 AI 后台小工具'
$aiRow.Controls.AddRange(@($lblAi, $btnStaleAi, $btnAllAi))

# 鼠标停在按钮上时的说明
$tips = New-Object Windows.Forms.ToolTip
$tips.AutoPopDelay = 15000; $tips.InitialDelay = 400
$tips.SetToolTip($btnStaleAi, "只关开了超过 $StaleHours 小时的 AI 后台小工具，基本是旧对话留下没关的，一般不会打断你正在用的对话。")
$tips.SetToolTip($btnAllAi, '关掉所有软件名下的 AI 后台小工具（playwright、REA、MCP 工具等），各软件本身不关。正在用这些工具的对话可能会报错，新开一个对话就会重新启动它们。')
$header.Controls.Add($lblCommit, 0, 0); $header.Controls.Add($bar, 1, 0)
$header.Controls.Add($lblPhys, 0, 1); $header.SetColumnSpan($lblPhys, 2)
$header.Controls.Add($lblHint, 0, 2); $header.SetColumnSpan($lblHint, 2)
$header.Controls.Add($aiRow, 0, 3); $header.SetColumnSpan($aiRow, 2)

function New-Grid {
    $g = New-Object Windows.Forms.DataGridView
    $g.Dock = 'Fill'; $g.AllowUserToAddRows = $false; $g.AllowUserToDeleteRows = $false
    $g.AllowUserToResizeRows = $false; $g.RowHeadersVisible = $false; $g.MultiSelect = $false
    $g.SelectionMode = 'FullRowSelect'; $g.AutoSizeColumnsMode = 'Fill'; $g.BackgroundColor = [Drawing.Color]::White
    $g.BorderStyle = 'None'; $g.ColumnHeadersHeightSizeMode = 'AutoSize'; $g.EnableHeadersVisualStyles = $false
    $g.ColumnHeadersDefaultCellStyle.BackColor = [Drawing.Color]::FromArgb(243, 243, 243)
    $g.ColumnHeadersDefaultCellStyle.Font = New-Object Drawing.Font('Microsoft YaHei UI', 9, [Drawing.FontStyle]::Bold)
    $g.DefaultCellStyle.SelectionBackColor = [Drawing.Color]::FromArgb(204, 228, 247)
    $g.DefaultCellStyle.SelectionForeColor = [Drawing.Color]::Black
    $g.RowTemplate.Height = S 26
    $g.GridColor = [Drawing.Color]::FromArgb(230, 230, 230)
    $g.CellBorderStyle = 'SingleHorizontal'
    # 勾选框点一下立即生效
    $g.Add_CurrentCellDirtyStateChanged({ if ($this.IsCurrentCellDirty) { [void]$this.CommitEdit('CurrentCellChange') } })
    # 右键先选中那一行，右键菜单再对它操作
    $g.Add_CellMouseDown({
        param($s, $e)
        if ($e.Button -eq 'Right' -and $e.RowIndex -ge 0) {
            $col = if ($e.ColumnIndex -ge 0 -and $s.Columns[$e.ColumnIndex].Visible) { $e.ColumnIndex } else { 0 }
            $s.CurrentCell = $s.Rows[$e.RowIndex].Cells[$col]
        }
    })
    $g
}

function Set-Columns($grid, $spec) {
    foreach ($s in $spec) {
        $col = $grid.Columns[$s[0]]
        if (-not $col) { continue }
        if ($s[1] -eq $null) { $col.Visible = $false; continue }
        $col.HeaderText = $s[1]; $col.FillWeight = $s[2]
        if ($s[0] -ne 'Sel') { $col.ReadOnly = $true }
        if ($s.Count -gt 3 -and $s[3]) {
            $col.DefaultCellStyle.Format = $s[3]
            $col.DefaultCellStyle.Alignment = 'MiddleRight'
        }
    }
}

$tblApps = New-Object Data.DataTable
foreach ($c in @(@('Sel', [bool]), @('Icon', [Drawing.Image]), @('Key', [string]), @('App', [string]), @('Kind', [string]),
        @('Count', [int]), @('CommitMB', [double]), @('WsMB', [double]), @('AiTools', [string]), @('Age', [string]),
        @('StartSort', [datetime]), @('Locked', [bool]), @('AiStale', [int]), @('SearchText', [string]))) {
    [void]$tblApps.Columns.Add($c[0], $c[1])
}
$tblProcs = New-Object Data.DataTable
foreach ($c in @(@('Sel', [bool]), @('Pid', [int]), @('Proc', [string]), @('Purpose', [string]), @('CommitMB', [double]),
        @('WsMB', [double]), @('Age', [string]), @('Order', [int]), @('Locked', [bool]), @('Stale', [bool]))) {
    [void]$tblProcs.Columns.Add($c[0], $c[1])
}

$gridApps = New-Grid
$gridProcs = New-Grid
$gridApps.DataSource = $tblApps
$gridProcs.DataSource = $tblProcs

# ---- 上表上方的工具条：搜索、显示系统进程、更新时间
$toolbar = New-Object Windows.Forms.FlowLayoutPanel
$toolbar.Dock = 'Top'; $toolbar.AutoSize = $true; $toolbar.WrapContents = $false
$toolbar.Padding = New-Object Windows.Forms.Padding((S 8), (S 4), (S 8), (S 4))
$lblSearch = New-Object Windows.Forms.Label
$lblSearch.Text = '搜索：'; $lblSearch.AutoSize = $true; $lblSearch.Margin = New-Object Windows.Forms.Padding(0, (S 6), 0, 0)
$txtSearch = New-Object Windows.Forms.TextBox
$txtSearch.Width = S 260; $txtSearch.Margin = New-Object Windows.Forms.Padding(0, (S 2), (S 12), 0)
$txtSearch.Add_HandleCreated({ [void][MemMonNative]::SendMessage($txtSearch.Handle, 0x1501, [IntPtr]1, '软件名或进程名，比如 chrome、node') })
$tips.SetToolTip($txtSearch, '既能搜软件名，也能搜进程名和用途，比如输入 node 或 playwright，就能看到这些进程挂在哪个软件下面，下表里命中的进程标成黄色。Esc 清空。')
$chkSystem = New-Object Windows.Forms.CheckBox
$chkSystem.Text = '显示系统进程和服务'; $chkSystem.AutoSize = $true
$chkSystem.Margin = New-Object Windows.Forms.Padding(0, (S 5), (S 16), 0)
$lblUpdated = New-Object Windows.Forms.Label
$lblUpdated.AutoSize = $true; $lblUpdated.ForeColor = [Drawing.Color]::DimGray
$lblUpdated.Margin = New-Object Windows.Forms.Padding(0, (S 6), 0, 0)
$toolbar.Controls.AddRange(@($lblSearch, $txtSearch, $chkSystem, $lblUpdated))

$split = New-Object Windows.Forms.SplitContainer
$split.Dock = 'Fill'; $split.Orientation = 'Horizontal'; $split.SplitterWidth = S 8
# 分隔线用浅灰底，中间画三个点，看得出来能拖
$split.BackColor = [Drawing.Color]::FromArgb(222, 222, 222)
$split.Panel1.BackColor = [Drawing.Color]::White
$split.Panel2.BackColor = [Drawing.Color]::White
$split.Panel1.Controls.Add($gridApps)
$split.Panel1.Controls.Add($toolbar)
$gridApps.BringToFront()

# 下表的标题栏：左边是说明，右边是收起 / 展开按钮；收起后只留这一条
$procHeader = New-Object Windows.Forms.Panel
$procHeader.Dock = 'Top'; $procHeader.Height = S 32
$procHeader.BackColor = [Drawing.Color]::FromArgb(245, 245, 245)
$lblProcs = New-Object Windows.Forms.Label
$lblProcs.Dock = 'Fill'; $lblProcs.AutoSize = $false; $lblProcs.TextAlign = 'MiddleLeft'; $lblProcs.AutoEllipsis = $true
$lblProcs.Padding = New-Object Windows.Forms.Padding((S 8), 0, 0, 0)
$btnToggle = New-Object Windows.Forms.Button
$btnToggle.Dock = 'Right'; $btnToggle.AutoSize = $true; $btnToggle.FlatStyle = 'Flat'; $btnToggle.Cursor = 'Hand'
$btnToggle.FlatAppearance.BorderSize = 0
$btnToggle.ForeColor = [Drawing.Color]::FromArgb(0, 95, 184)
$btnToggle.Font = New-Object Drawing.Font('Microsoft YaHei UI', 9, [Drawing.FontStyle]::Bold)
$btnToggle.Padding = New-Object Windows.Forms.Padding((S 8), 0, (S 8), 0)
$procHeader.Controls.Add($lblProcs)
$procHeader.Controls.Add($btnToggle)
$lblProcs.BringToFront()
$split.Panel2.Controls.Add($gridProcs)
$split.Panel2.Controls.Add($procHeader)
$gridProcs.BringToFront()

$split.Add_Paint({
    param($s, $e)
    $r = $s.SplitterRectangle
    $brush = New-Object Drawing.SolidBrush([Drawing.Color]::FromArgb(140, 140, 140))
    $d = S 4; $gap = S 10
    $cx = $r.X + $r.Width / 2; $cy = $r.Y + ($r.Height - $d) / 2
    foreach ($i in -1..1) { $e.Graphics.FillEllipse($brush, [float]($cx + $i * $gap - $d / 2), [float]$cy, [float]$d, [float]$d) }
    $brush.Dispose()
})

# ---- 底部按钮
$bottom = New-Object Windows.Forms.FlowLayoutPanel
$bottom.Dock = 'Bottom'; $bottom.AutoSize = $true; $bottom.WrapContents = $true
$bottom.Padding = New-Object Windows.Forms.Padding((S 8), (S 6), (S 8), (S 8))
$btnRefresh = New-Button '刷新列表'
$btnCloseApps = New-Button '关闭勾选的软件'
$btnCloseApps.ForeColor = [Drawing.Color]::FromArgb(180, 30, 30)
$btnCloseAi = New-Button '只关所选软件的 AI 后台小工具'
$btnCloseProcs = New-Button '结束勾选的进程'
$lblTip = New-Object Windows.Forms.Label
$lblTip.AutoSize = $true; $lblTip.ForeColor = [Drawing.Color]::DimGray
$lblTip.Margin = New-Object Windows.Forms.Padding((S 4), (S 8), 0, 0)
$lblTip.Text = '右键任意一行也能操作。快捷键：F5 刷新、Ctrl+F 搜索、空格 勾选、Delete 关闭。灰色的是系统进程和服务，不能在这里关。'
$bottom.Controls.AddRange(@($btnRefresh, $btnCloseApps, $btnCloseAi, $btnCloseProcs, $lblTip))
$tips.SetToolTip($btnRefresh, '重新读取所有进程（F5）。窗口切回来时，如果列表超过 1 分钟没更新、又没勾选东西，也会自动刷新。')
$tips.SetToolTip($btnCloseApps, '关掉上表里勾选的软件，连同它的全部子进程。没勾选时按 Delete 关的是当前选中的那一个。')
$tips.SetToolTip($btnCloseAi, '只关上表当前选中那个软件名下的 AI 后台小工具，软件本身不关。')
$tips.SetToolTip($btnCloseProcs, '结束下表里勾选的进程，连同它们启动的子进程。')

$form.Controls.Add($split)
$form.Controls.Add($header)
$form.Controls.Add($bottom)
$split.BringToFront()

# ---- 右键菜单
$menuApps = New-Object Windows.Forms.ContextMenuStrip
$miAppClose = $menuApps.Items.Add('关闭这个软件')
$miAppAi = $menuApps.Items.Add('只关它的 AI 后台小工具')
[void]$menuApps.Items.Add((New-Object Windows.Forms.ToolStripSeparator))
$miAppOpen = $menuApps.Items.Add('打开文件所在位置')
$miAppCopy = $menuApps.Items.Add('复制程序路径')
$gridApps.ContextMenuStrip = $menuApps

$menuProcs = New-Object Windows.Forms.ContextMenuStrip
$miProcEnd = $menuProcs.Items.Add('结束这个进程（连同它的子进程）')
[void]$menuProcs.Items.Add((New-Object Windows.Forms.ToolStripSeparator))
$miProcOpen = $menuProcs.Items.Add('打开文件所在位置')
$miProcCopy = $menuProcs.Items.Add('复制命令行')
$gridProcs.ContextMenuStrip = $menuProcs

# 表格列要等窗口显示、数据绑定后才生成，所以在 Shown 里设置
function Initialize-Columns {
    Set-Columns $gridApps @(
        @('Sel', '关', 26), @('Icon', '', 22), @('Key', $null), @('App', '软件', 200), @('Kind', '类型', 80),
        @('Count', '进程数', 52, 'N0'), @('CommitMB', '预订 (MB)', 72, 'N0'), @('WsMB', '实际占用 (MB)', 80, 'N0'),
        @('AiTools', 'AI 后台小工具', 120), @('Age', '已运行', 90), @('StartSort', $null), @('Locked', $null),
        @('AiStale', $null), @('SearchText', $null))
    Set-Columns $gridProcs @(
        @('Sel', '关', 26), @('Pid', 'PID', 52), @('Proc', '进程', 170), @('Purpose', '用途', 250),
        @('CommitMB', '预订 (MB)', 70, 'N0'), @('WsMB', '实际占用 (MB)', 80, 'N0'), @('Age', '已运行', 90),
        @('Order', $null), @('Locked', $null), @('Stale', $null))
    $gridApps.Columns['Age'].SortMode = 'Programmatic'
    $gridApps.Columns['Icon'].SortMode = 'NotSortable'

    # 鼠标停在列名上时的说明
    $commitTip = '程序向系统订下的内存（提交大小）。所有程序的预订加起来不能超过上限，快满了程序会卡住、闪退或提示内存不足。'
    $wsTip = '现在真正占着的物理内存（专用工作集），和任务管理器「内存」一列的口径一样。'
    foreach ($grid in @($gridApps, $gridProcs)) {
        $grid.Columns['CommitMB'].ToolTipText = $commitTip
        $grid.Columns['WsMB'].ToolTipText = $wsTip
        $grid.Columns['Sel'].ToolTipText = '勾选要关的；也可以选中一行按空格'
    }
    $gridApps.Columns['AiTools'].ToolTipText = "这个软件开的 playwright、REA、MCP 等后台小工具，「只关 AI 后台小工具」关的就是这些。标橙色表示其中有开了超过 $StaleHours 小时的。"
    $gridApps.Columns['Kind'].ToolTipText = '应用：你打开的软件；后台程序：自己在后台跑的；你的后台服务：local-config.json 里登记的你自己的服务；系统、系统服务：Windows 和驱动的，不能在这里关。'
    $gridApps.Columns['Count'].ToolTipText = '这个软件连同它启动的子进程一共多少个'
    $gridProcs.Columns['Purpose'].ToolTipText = "这个进程是干什么的。标橙色的是开了超过 $StaleHours 小时的 AI 后台小工具；搜索命中的标黄色。"
}

$script:Snap = $null
$script:Updating = $false
$script:ShownKey = $null
$script:PreferredKey = $null
$script:AiSummary = @()

function Update-Header($t) {
    $pct = [int][math]::Round(100 * $t.CommitUsed / $t.CommitLimit)
    $lblCommit.Text = '已预订 {0:N1} / {1:N1} GB（{2}%）' -f ($t.CommitUsed / 1GB), ($t.CommitLimit / 1GB), $pct
    $lblPhys.Text = '实际占用物理内存 {0:N1} / {1:N1} GB（{2}%）' -f ($t.PhysUsed / 1GB), ($t.PhysTotal / 1GB), [int][math]::Round(100 * $t.PhysUsed / $t.PhysTotal)
    $barFill.Width = [int]($bar.ClientSize.Width * [math]::Min(100, $pct) / 100)
    $color = if ($pct -ge 90) { [Drawing.Color]::FromArgb(196, 43, 28) } elseif ($pct -ge 75) { $Orange } else { [Drawing.Color]::FromArgb(16, 124, 16) }
    $barFill.BackColor = $color
    $lblCommit.ForeColor = if ($pct -ge 75) { $color } else { [Drawing.Color]::Black }
    # 任务栏上也能看到
    $form.Text = "内存占用查看 — 已预订 $pct%"
}

# 系统进程筛选 + 搜索框筛选（软件名、进程名、用途都能搜）
function Update-AppFilter {
    $parts = New-Object System.Collections.Generic.List[string]
    if (-not $chkSystem.Checked) { $parts.Add("Kind NOT IN ('系统', '系统服务', '本工具')") }
    $q = $txtSearch.Text.Trim()
    if ($q) {
        # DataView 的 LIKE 里 [ ] * % 要用方括号转义，单引号要写两遍
        $esc = -join ($q.ToCharArray() | ForEach-Object { if ('[]*%'.Contains([string]$_)) { "[$_]" } elseif ($_ -eq "'") { "''" } else { [string]$_ } })
        $parts.Add("SearchText LIKE '%$esc%'")
    }
    # 筛选后尽量停在最后选中的那个软件上（筛选到空列表再清空也一样），下表就不会跟着换
    $key = $script:PreferredKey
    $tblApps.DefaultView.RowFilter = $parts -join ' AND '
    if ($key -and $gridApps.CurrentRow -and "$($gridApps.CurrentRow.Cells['Key'].Value)" -ne $key) {
        foreach ($row in $gridApps.Rows) { if ("$($row.Cells['Key'].Value)" -eq $key) { $gridApps.CurrentCell = $row.Cells['App']; break } }
    }
    # 下表里搜索命中的进程重新标色
    & $styleRows $gridProcs
}

function Update-AiSummary {
    $script:AiSummary = @($script:Snap.Groups | Where-Object { $_.AiTargets.Count } | ForEach-Object {
        [pscustomobject]@{ Group = $_; Targets = $_.AiTargets; MB = $_.AiCommit / 1MB; Stale = $_.AiStaleTargets }
    })
    $staleCount = ($script:AiSummary | ForEach-Object { $_.Stale.Count } | Measure-Object -Sum).Sum + 0
    if ($script:AiSummary.Count) {
        $count = ($script:AiSummary | ForEach-Object { $_.Targets.Count } | Measure-Object -Sum).Sum
        $mb = ($script:AiSummary | Measure-Object MB -Sum).Sum
        $by = ($script:AiSummary | Sort-Object MB -Descending | ForEach-Object { '{0} {1} 个' -f $_.Group.Label, $_.Targets.Count }) -join '、'
        $lblAi.Text = 'AI 后台小工具：共 {0} 个进程，预订 {1:N1} GB（{2}）' -f $count, ($mb / 1024), $by
        if ($staleCount) { $lblAi.Text += "，其中 $staleCount 个开了超过 $StaleHours 小时" }
        $lblAi.ForeColor = if ($mb -ge 1024 -or $staleCount) { $Orange } else { [Drawing.Color]::Black }
        $btnAllAi.Enabled = $true
    } else {
        $lblAi.Text = 'AI 后台小工具：目前没有'
        $lblAi.ForeColor = [Drawing.Color]::DimGray
        $btnAllAi.Enabled = $false
    }
    $btnStaleAi.Enabled = $staleCount -gt 0
    $btnStaleAi.Text = if ($staleCount) { "只关开了 $StaleHours 小时以上的（$staleCount 个）" } else { "只关开了 $StaleHours 小时以上的" }
}

function Update-Data {
    $form.Cursor = 'WaitCursor'
    $lblUpdated.Text = '正在读取所有进程…'
    $lblUpdated.Refresh()
    try {
        $selectedKey = $null
        if ($gridApps.CurrentRow) { $selectedKey = $gridApps.CurrentRow.Cells['Key'].Value }
        $script:Snap = Get-MemorySnapshot
        $script:Updating = $true
        $tblApps.Rows.Clear()
        foreach ($g in $script:Snap.Groups) {
            $ai = if ($g.AiTargets.Count) { '{0} 个，{1:N0} MB' -f $g.AiTargets.Count, ($g.AiCommit / 1MB) } else { '' }
            if ($g.AiStaleTargets.Count) { $ai += "（$($g.AiStaleTargets.Count) 个超 $StaleHours 小时）" }
            $start = if ($g.Start) { $g.Start } else { [datetime]::MaxValue }
            # 搜索范围：软件名 + 名下每个进程的名字和用途
            $search = $g.Label + ' ' + (($g.Rows | ForEach-Object { "$($_.Name) $($_.Purpose)" }) -join ' ')
            [void]$tblApps.Rows.Add($false, (Get-AppIcon $g.ExePath), $g.Key, $g.Label, $g.Kind, $g.Procs.Count,
                [math]::Round($g.Commit / 1MB), [math]::Round($g.Ws / 1MB), $ai, (Format-Age $g.Start), $start, $g.Protected,
                $g.AiStaleTargets.Count, $search)
        }
        if (-not $tblApps.DefaultView.Sort) { $tblApps.DefaultView.Sort = 'CommitMB DESC' }
        Update-AppFilter
        Update-Header $script:Snap
        Update-AiSummary
        $lblUpdated.Text = '列表更新于 {0:HH:mm:ss}（F5 刷新）' -f $script:Snap.Taken
        $script:Updating = $false
        $target = $null
        foreach ($row in $gridApps.Rows) { if ($row.Cells['Key'].Value -eq $selectedKey) { $target = $row; break } }
        if (-not $target -and $gridApps.Rows.Count) { $target = $gridApps.Rows[0] }
        if ($target) { $gridApps.CurrentCell = $target.Cells['App'] }
        Show-Procs -Force
    } finally {
        $script:Updating = $false
        $form.Cursor = 'Default'
    }
}

function Get-Group([string]$key) { $script:Snap.Groups | Where-Object Key -eq $key | Select-Object -First 1 }
function Get-CurrentGroup { if ($gridApps.CurrentRow) { Get-Group "$($gridApps.CurrentRow.Cells['Key'].Value)" } }
function Get-CurrentProc {
    $g = Get-CurrentGroup
    if (-not $g -or -not $gridProcs.CurrentRow) { return $null }
    $id = [int]$gridProcs.CurrentRow.Cells['Pid'].Value
    $g.Rows | Where-Object { [int]$_.Pid -eq $id } | Select-Object -First 1
}

# 下表跟着上表的当前行走；同一个软件不重建，免得把下表已经勾好的清掉
function Show-Procs([switch]$Force) {
    if ($script:Updating) { return }
    $key = if ($gridApps.CurrentRow) { "$($gridApps.CurrentRow.Cells['Key'].Value)" } else { '' }
    if ($key) { $script:PreferredKey = $key }
    if (-not $Force -and $key -eq $script:ShownKey) { return }
    $script:ShownKey = $key
    $tblProcs.Rows.Clear()
    if (-not $key) { $lblProcs.Text = ''; return }
    $g = Get-Group $key
    if (-not $g) { return }
    $i = 0
    $staleIds = New-Object System.Collections.Generic.HashSet[int]
    foreach ($s in $g.AiStaleTargets) { [void]$staleIds.Add([int]$s.Pid) }
    foreach ($r in $g.Rows) {
        $indent = if ($r.Depth) { ('　' * ($r.Depth - 1)) + '└ ' } else { '' }
        [void]$tblProcs.Rows.Add($false, $r.Pid, "$indent$($r.Name)", $r.Purpose, [math]::Round($r.Commit / 1MB),
            [math]::Round($r.Ws / 1MB), (Format-Age $r.Start), $i, $g.Protected, $staleIds.Contains([int]$r.Pid))
        $i++
    }
    $tblProcs.DefaultView.Sort = 'Order ASC'
    $lblProcs.Text = if ($g.Protected) { "$($g.Label) 的进程（$($g.Procs.Count) 个）——系统进程，只能查看" }
        else {
            $t = "$($g.Label) 的进程（$($g.Procs.Count) 个）——勾选后点「结束勾选的进程」，会连同它启动的子进程一起结束"
            if ($staleIds.Count) { $t += "。橙色的 $($staleIds.Count) 个是开了超过 $StaleHours 小时的 AI 后台小工具" }
            $t
        }
    & $styleRows $gridProcs
}

# 灰掉不能关的行，标出预订大户、放了很久的 AI 小工具、搜索命中的进程
$SearchHit = [Drawing.Color]::FromArgb(255, 247, 186)
$styleRows = {
    param($grid)
    $isProcs = [bool]$grid.Columns['Stale']
    $q = $txtSearch.Text.Trim()
    foreach ($row in $grid.Rows) {
        $locked = [bool]$row.Cells['Locked'].Value
        $row.Cells['Sel'].ReadOnly = $locked
        $row.DefaultCellStyle.ForeColor = if ($locked) { [Drawing.Color]::Gray }
            elseif ($isProcs -and [bool]$row.Cells['Stale'].Value) { $Orange } else { [Drawing.Color]::Black }
        $mb = [double]$row.Cells['CommitMB'].Value
        $row.Cells['CommitMB'].Style.BackColor = if ($mb -ge 2048) { [Drawing.Color]::FromArgb(253, 226, 225) }
            elseif ($mb -ge 1024) { [Drawing.Color]::FromArgb(255, 244, 206) } else { [Drawing.Color]::Empty }
        if ($isProcs) {
            $hit = $q -and ("$($row.Cells['Proc'].Value) $($row.Cells['Purpose'].Value)".IndexOf($q, [StringComparison]::OrdinalIgnoreCase) -ge 0)
            $row.DefaultCellStyle.BackColor = if ($hit) { $SearchHit } else { [Drawing.Color]::Empty }
        } else {
            $row.Cells['AiTools'].Style.ForeColor = if (-not $locked -and [int]$row.Cells['AiStale'].Value -gt 0) { $Orange } else { [Drawing.Color]::Empty }
        }
    }
}
$gridApps.Add_DataBindingComplete({ & $styleRows $gridApps })
$gridProcs.Add_DataBindingComplete({ & $styleRows $gridProcs })
# 用 CurrentCellChanged 而不是 SelectionChanged：后者触发时 CurrentRow 可能还是旧的那一行
$gridApps.Add_CurrentCellChanged({ Show-Procs })
$gridApps.Add_ColumnHeaderMouseClick({
    param($s, $e)
    if ($gridApps.Columns[$e.ColumnIndex].Name -eq 'Age') {
        $tblApps.DefaultView.Sort = if ($tblApps.DefaultView.Sort -eq 'StartSort ASC') { 'StartSort DESC' } else { 'StartSort ASC' }
    }
})
$chkSystem.Add_CheckedChanged({ Update-AppFilter })
$txtSearch.Add_TextChanged({ Update-AppFilter })

# 弹窗统一走这里；-UiTest 时不弹窗，把内容记到日志，按测试预设的回答返回（默认“是”）
$script:TestAnswers = New-Object System.Collections.Queue
function Show-Box([string]$text, [string]$title, [string]$buttons = 'OK', [string]$icon = 'None', [string]$default = 'Button1') {
    if ($UiTest) {
        Add-Content -LiteralPath $UiTest -Value "[弹窗：$title] $($text -replace "`r`n", ' / ')" -Encoding UTF8
        if ($buttons -eq 'YesNo' -and $script:TestAnswers.Count) { return $script:TestAnswers.Dequeue() }
        return 'Yes'
    }
    [Windows.Forms.MessageBox]::Show($form, $text, $title, $buttons, $icon, $default)
}

# 按钮和菜单里出错时给出提示，不让整个窗口弹 .NET 异常框
function Invoke-Safe([scriptblock]$action) {
    try { & $action }
    catch {
        $form.Cursor = 'Default'
        [void](Show-Box "出错了，什么都没有关闭：`r`n$($_.Exception.Message)（第 $($_.InvocationInfo.ScriptLineNumber) 行）" '内存占用查看' 'OK' 'Error')
    }
}

# $restartKeys：整个软件被关掉的那些分组；关完以后检查它们有没有自己又启动起来
function Confirm-AndStop($groupsToClose, $targets, [string]$title, [string]$extraWarning, $restartKeys) {
    $lines = New-Object System.Collections.Generic.List[string]
    $warn = New-Object System.Collections.Generic.List[string]
    foreach ($item in $groupsToClose) {
        $lines.Add(('• {0} — {1} 个进程，预订约 {2:N0} MB' -f $item.Label, $item.Count, $item.MB))
        if ($extraWarning) { continue }
        if ($item.Group.Kind -eq '你的后台服务') { $warn.Add("⚠ $($item.Group.Label) 是你自己的后台服务，关掉后对应功能会停止，直到下次开机或手动启动。") }
        if ($AppWarnings.ContainsKey($item.Group.RootName)) { $warn.Add("⚠ $($AppWarnings[$item.Group.RootName])") }
    }
    if ($extraWarning) { $warn.Add("⚠ $extraWarning") }
    $msg = "将要结束：`r`n" + ($lines -join "`r`n")
    if ($warn.Count) { $msg += "`r`n`r`n" + (($warn | Select-Object -Unique) -join "`r`n") }
    $msg += "`r`n`r`n有窗口的程序会先尝试正常关闭（最多等 3 秒），之后强制结束，没保存的内容可能丢失。确定吗？"
    $answer = Show-Box $msg $title 'YesNo' 'Warning' 'Button2'
    if ("$answer" -ne 'Yes') { return }
    $form.Cursor = 'WaitCursor'
    $before = Get-MemTotals
    $killedAt = Get-Date
    $res = Stop-Targets $targets
    # 等一下再重新读：一来数字更准，二来带守护进程的软件这时候已经被拉起来了
    Start-Sleep -Milliseconds 1200
    Update-Data
    $form.Cursor = 'Default'
    $after = $script:Snap
    $diff = ($before.CommitUsed - $after.CommitUsed) / 1GB
    $text = '已结束 {0} 个进程。' -f $res.Done
    $text += "`r`n已预订：{0:N1} GB → {1:N1} GB" -f ($before.CommitUsed / 1GB), ($after.CommitUsed / 1GB)
    $text += if ($diff -ge 0.05) { '（少了 {0:N1} GB）' -f $diff } else { '（变化不大，可能有其他程序同时在占用）' }
    $restarted = @(foreach ($key in @($restartKeys)) {
        $g = Get-Group $key
        if ($g -and $g.Start -and $g.Start -ge $killedAt.AddSeconds(-1)) { $g.Label }
    })
    if ($restarted.Count) {
        $text += "`r`n`r`n⚠ " + ($restarted -join '、') + ' 关掉后马上又自己启动了，说明它有守护进程或开机服务。要彻底不让它运行，得在它自己的设置里关掉“开机启动 / 后台运行”。'
    }
    if ($res.Failed.Count) { $text += "`r`n`r`n以下进程没能结束（可能需要管理员权限）：`r`n" + (($res.Failed | Select-Object -First 15) -join "`r`n") }
    [void](Show-Box $text $title 'OK' 'Information')
}

function Close-Groups($groups) {
    $items = @(foreach ($g in $groups) { [pscustomobject]@{ Group = $g; Label = $g.Label; Count = $g.Procs.Count; MB = $g.Commit / 1MB } })
    $targets = @(foreach ($g in $groups) { $g.Rows })
    Confirm-AndStop $items $targets '关闭软件' $null @($groups | ForEach-Object Key)
}

function Close-ProcsInGroup($g, [int[]]$picked) {
    $ids = New-Object System.Collections.Generic.HashSet[int]
    foreach ($id in $picked) { foreach ($d in (Get-Descendants $script:Snap.Children $id)) { [void]$ids.Add($d) } }
    $targets = @($g.Rows | Where-Object { $ids.Contains([int]$_.Pid) })
    $mb = ($targets | Measure-Object Commit -Sum).Sum / 1MB
    $item = [pscustomobject]@{ Group = $g; Label = "$($g.Label) 里选中的进程（含子进程）"; Count = $targets.Count; MB = $mb }
    Confirm-AndStop @($item) $targets '结束进程'
}

function Open-Location([string]$path) {
    if ($path -and (Test-Path -LiteralPath $path)) { Start-Process explorer.exe "/select,`"$path`"" }
    else { [void](Show-Box '找不到这个程序的文件位置（可能需要管理员权限才能读取）。' '打开文件所在位置') }
}

function Copy-Text([string]$text) {
    if (-not $text) { [void](Show-Box '没有可复制的内容（可能需要管理员权限才能读取）。' '复制'); return }
    if (-not $UiTest) { [Windows.Forms.Clipboard]::SetText($text) }
}

$btnRefresh.Add_Click({ Invoke-Safe { Update-Data } })

$btnCloseApps.Add_Click({ Invoke-Safe {
    [void]$gridApps.EndEdit()
    $picked = @($tblApps.Rows | Where-Object { $_.Sel -and -not $_.Locked })
    if (-not $picked.Count) { [void](Show-Box '先在上面的列表里勾选要关闭的软件。' '关闭软件'); return }
    Close-Groups @(foreach ($r in $picked) { Get-Group $r.Key })
} })

$btnCloseProcs.Add_Click({ Invoke-Safe {
    [void]$gridProcs.EndEdit()
    $g = Get-CurrentGroup
    $picked = @($tblProcs.Rows | Where-Object { $_.Sel -and -not $_.Locked } | ForEach-Object { [int]$_.Pid })
    if (-not $g -or -not $picked.Count) { [void](Show-Box '先在下面的进程列表里勾选要结束的进程。' '结束进程'); return }
    Close-ProcsInGroup $g $picked
} })

$btnCloseAi.Add_Click({ Invoke-Safe {
    $g = Get-CurrentGroup
    if (-not $g) { return }
    if ($g.Protected) { [void](Show-Box "$($g.Label) 是系统进程，不能在这里关。" '关闭 AI 后台小工具'); return }
    $targets = @($g.AiTargets)
    if (-not $targets.Count) {
        [void](Show-Box "$($g.Label) 名下没有可以单独关掉的 AI 后台小工具（playwright、REA、MCP 工具等）。" '关闭 AI 后台小工具')
        return
    }
    $mb = ($targets | Measure-Object Commit -Sum).Sum / 1MB
    $item = [pscustomobject]@{ Group = $g; Label = "$($g.Label) 的 AI 后台小工具"; Count = $targets.Count; MB = $mb }
    Confirm-AndStop @($item) $targets '关闭 AI 后台小工具' "$($g.Label) 本身不会关。正在用这些工具的对话可能会报错，新开一个对话就会重新启动它们。"
} })

$btnAllAi.Add_Click({ Invoke-Safe {
    Update-Data
    $all = @($script:AiSummary)
    if (-not $all.Count) { [void](Show-Box '目前没有 AI 后台小工具。' '关闭全部 AI 后台小工具'); return }
    $items = @(foreach ($a in $all) { [pscustomobject]@{ Group = $a.Group; Label = "$($a.Group.Label) 的 AI 后台小工具"; Count = $a.Targets.Count; MB = $a.MB } })
    $targets = @(foreach ($a in $all) { $a.Targets })
    Confirm-AndStop $items $targets '关闭全部 AI 后台小工具' '各个软件本身都不会关。正在用这些工具的对话可能会报错，新开一个对话就会重新启动它们。'
} })

$btnStaleAi.Add_Click({ Invoke-Safe {
    Update-Data
    $all = @($script:AiSummary | Where-Object { $_.Stale.Count })
    if (-not $all.Count) { [void](Show-Box "现在没有开了超过 $StaleHours 小时的 AI 后台小工具。" '关闭旧的 AI 后台小工具'); return }
    $items = @(foreach ($a in $all) {
        [pscustomobject]@{ Group = $a.Group; Label = "$($a.Group.Label) 开了超过 $StaleHours 小时的 AI 后台小工具"; Count = $a.Stale.Count
            MB = ($a.Stale | Measure-Object Commit -Sum).Sum / 1MB }
    })
    $targets = @(foreach ($a in $all) { $a.Stale })
    Confirm-AndStop $items $targets '关闭旧的 AI 后台小工具' "各个软件本身都不会关。这些小工具已经开了超过 $StaleHours 小时，基本是旧对话留下的；万一有对话还在用，新开一个对话就会重新启动它们。"
} })

$menuApps.Add_Opening({
    param($s, $e)
    $g = Get-CurrentGroup
    if (-not $g) { $e.Cancel = $true; return }
    $miAppClose.Enabled = -not $g.Protected
    $miAppAi.Enabled = (-not $g.Protected) -and $g.AiTargets.Count -gt 0
    $miAppOpen.Enabled = [bool]$g.ExePath
    $miAppCopy.Enabled = [bool]$g.ExePath
})
$miAppClose.Add_Click({ Invoke-Safe { $g = Get-CurrentGroup; if ($g -and -not $g.Protected) { Close-Groups @($g) } } })
$miAppAi.Add_Click({ $btnCloseAi.PerformClick() })
$miAppOpen.Add_Click({ Invoke-Safe { Open-Location (Get-CurrentGroup).ExePath } })
$miAppCopy.Add_Click({ Invoke-Safe { Copy-Text (Get-CurrentGroup).ExePath } })

$menuProcs.Add_Opening({
    param($s, $e)
    $p = Get-CurrentProc
    if (-not $p) { $e.Cancel = $true; return }
    $miProcEnd.Enabled = -not (Get-CurrentGroup).Protected
    $miProcOpen.Enabled = [bool]$p.Path
    $miProcCopy.Enabled = [bool]$p.CommandLine
})
$miProcEnd.Add_Click({ Invoke-Safe {
    $g = Get-CurrentGroup; $p = Get-CurrentProc
    if ($g -and $p -and -not $g.Protected) { Close-ProcsInGroup $g @([int]$p.Pid) }
} })
$miProcOpen.Add_Click({ Invoke-Safe { Open-Location (Get-CurrentProc).Path } })
$miProcCopy.Add_Click({ Invoke-Safe { Copy-Text (Get-CurrentProc).CommandLine } })

# ---- 快捷键：F5 刷新、Ctrl+F 搜索、Esc 清空搜索、空格勾选、Delete 关闭
function Invoke-Shortcut([Windows.Forms.KeyEventArgs]$e) {
    $handled = $true
    if ($e.KeyCode -eq 'F5') { Invoke-Safe { Update-Data } }
    elseif ($e.Control -and $e.KeyCode -eq 'F') { [void]$txtSearch.Focus(); $txtSearch.SelectAll() }
    elseif ($e.KeyCode -eq 'Escape' -and $txtSearch.Text) { $txtSearch.Text = ''; [void]$gridApps.Focus() }
    elseif ($e.KeyCode -eq 'Space' -and -not $txtSearch.Focused) {
        # 在表格里按空格：勾上 / 取消当前这一行
        $grid = if ($gridProcs.Focused) { $gridProcs } else { $gridApps }
        if ($grid.CurrentRow -and -not [bool]$grid.CurrentRow.Cells['Locked'].Value) {
            [void]$grid.EndEdit()
            # 直接改数据表里的那一行，按钮马上就能读到
            $row = $grid.CurrentRow.DataBoundItem.Row
            $row['Sel'] = -not [bool]$row['Sel']
        }
    }
    elseif ($e.KeyCode -eq 'Delete' -and -not $txtSearch.Focused) {
        # 有勾选的就关勾选的；没有就关当前选中的那一行（都会先弹窗确认）
        if ($gridProcs.Focused) {
            if (@($tblProcs.Rows | Where-Object { $_.Sel }).Count) { $btnCloseProcs.PerformClick() } else { $miProcEnd.PerformClick() }
        } else {
            if (@($tblApps.Rows | Where-Object { $_.Sel }).Count) { $btnCloseApps.PerformClick() } else { $miAppClose.PerformClick() }
        }
    }
    else { $handled = $false }
    if ($handled) { $e.Handled = $true; $e.SuppressKeyPress = $true }
}
$form.KeyPreview = $true
$form.Add_KeyDown({ param($s, $e) Invoke-Shortcut $e })

# 切回这个窗口时，列表超过 1 分钟没刷新、又没勾选任何东西，就自动刷新一次（有勾选时不动，免得清掉）
function Invoke-AutoRefresh {
    if (-not $script:Snap -or $script:Updating) { return $false }
    if (((Get-Date) - $script:Snap.Taken).TotalSeconds -lt 60) { return $false }
    if (@($tblApps.Rows | Where-Object { $_.Sel }).Count -or @($tblProcs.Rows | Where-Object { $_.Sel }).Count) { return $false }
    Invoke-Safe { Update-Data }
    $true
}
$form.Add_Activated({ [void](Invoke-AutoRefresh) })

# 顶部数字每 3 秒刷新（只读总数，不重建列表，不影响勾选）
$timer = New-Object Windows.Forms.Timer
$timer.Interval = 3000
$timer.Add_Tick({ try { Update-Header (Get-MemTotals) } catch {} })
# ---- 下表收起 / 展开：按钮、双击标题栏或分隔线都能切换；把分隔线拖到底也算收起
$script:ProcsCollapsed = $false
$script:ExpandedDistance = $null
$script:SettingSplit = $false

function Get-CollapsedDistance { $split.Height - $split.SplitterWidth - $split.Panel2MinSize }

function Update-ToggleText {
    $btnToggle.Text = if ($script:ProcsCollapsed) { '▲ 展开进程列表' } else { '▼ 收起进程列表' }
}

function Set-ProcsCollapsed([bool]$collapsed) {
    $script:SettingSplit = $true
    try {
        if ($collapsed) {
            if (-not $script:ProcsCollapsed) { $script:ExpandedDistance = $split.SplitterDistance }
            $split.SplitterDistance = [math]::Max($split.Panel1MinSize, (Get-CollapsedDistance))
        } else {
            $d = $script:ExpandedDistance
            if (-not $d -or $d -ge (Get-CollapsedDistance) - (S 40)) { $d = [int]($split.Height * 0.56) }
            $split.SplitterDistance = $d
        }
    } finally { $script:SettingSplit = $false }
    $script:ProcsCollapsed = $collapsed
    Update-ToggleText
}

$split.Add_SplitterMoved({
    $split.Invalidate()
    if ($script:SettingSplit) { return }
    # 用户自己拖的：拖到底算收起；停在中间就记下这个高度，下次展开恢复到这里
    if ($split.Panel2.Height -le $split.Panel2MinSize + (S 6)) { $script:ProcsCollapsed = $true }
    else { $script:ProcsCollapsed = $false; $script:ExpandedDistance = $split.SplitterDistance }
    Update-ToggleText
})
# 窗口大小变了，收起状态要保持贴底
$split.Add_SizeChanged({ if ($script:ProcsCollapsed -and $split.Height -gt 0) { Set-ProcsCollapsed $true } })
$btnToggle.Add_Click({ Set-ProcsCollapsed (-not $script:ProcsCollapsed) })
$procHeader.Add_DoubleClick({ Set-ProcsCollapsed (-not $script:ProcsCollapsed) })
$lblProcs.Add_DoubleClick({ Set-ProcsCollapsed (-not $script:ProcsCollapsed) })
$split.Add_MouseDoubleClick({
    param($s, $e)
    if ($split.SplitterRectangle.Contains($e.Location)) { Set-ProcsCollapsed (-not $script:ProcsCollapsed) }
})
# 收起时双击上面某个软件，自动展开看它的进程
$gridApps.Add_CellDoubleClick({
    param($s, $e)
    if ($e.RowIndex -ge 0 -and $script:ProcsCollapsed) { Set-ProcsCollapsed $false }
})

# ---- 记住窗口位置大小、上下比例、是否收起、是否显示系统进程
$SettingsPath = Join-Path $env:LOCALAPPDATA 'memory-monitor\settings.json'
$script:Settings = $null
if (-not $Snapshot -and -not $UiTest -and (Test-Path -LiteralPath $SettingsPath)) {
    try { $script:Settings = Get-Content -LiteralPath $SettingsPath -Raw -Encoding UTF8 | ConvertFrom-Json } catch {}
}
if ($script:Settings) {
    $st = $script:Settings
    $rect = New-Object Drawing.Rectangle([int]$st.X, [int]$st.Y, [int]$st.Width, [int]$st.Height)
    # 只有还落在某块屏幕上才恢复位置，免得外接屏拔掉后窗口跑到看不见的地方
    if ([Windows.Forms.Screen]::AllScreens | Where-Object { $_.WorkingArea.IntersectsWith($rect) }) {
        $form.StartPosition = 'Manual'; $form.Bounds = $rect
    }
    if ($st.Maximized) { $form.WindowState = 'Maximized' }
    $chkSystem.Checked = [bool]$st.ShowSystem
}

function Save-Settings {
    if ($Snapshot -or $UiTest) { return }
    try {
        $b = if ($form.WindowState -eq 'Normal') { $form.Bounds } else { $form.RestoreBounds }
        $ratio = if ($script:ExpandedDistance -and $split.Height) { $script:ExpandedDistance / [double]$split.Height } else { 0.56 }
        $o = [ordered]@{
            X = $b.X; Y = $b.Y; Width = $b.Width; Height = $b.Height; Maximized = ($form.WindowState -eq 'Maximized')
            SplitRatio = [math]::Round($ratio, 3); Collapsed = $script:ProcsCollapsed; ShowSystem = $chkSystem.Checked
        }
        New-Item -ItemType Directory -Force -Path (Split-Path $SettingsPath) | Out-Null
        $o | ConvertTo-Json | Set-Content -LiteralPath $SettingsPath -Encoding UTF8
    } catch {}
}

$form.Add_FormClosing({ $timer.Stop(); Save-Settings })

$form.Add_Shown({
    $ratio = if ($script:Settings -and $script:Settings.SplitRatio) { [double]$script:Settings.SplitRatio } else { 0.56 }
    $ratio = [math]::Min(0.85, [math]::Max(0.2, $ratio))
    $script:SettingSplit = $true
    try {
        $script:ExpandedDistance = [int]($split.Height * $ratio)
        $split.SplitterDistance = $script:ExpandedDistance
        $split.Panel1MinSize = S 120
        $split.Panel2MinSize = $procHeader.Height
    } catch {} finally { $script:SettingSplit = $false }
    Update-ToggleText
    if ($script:Settings -and $script:Settings.Collapsed) { Set-ProcsCollapsed $true }
    Initialize-Columns
    Invoke-Safe { Update-Data }
    if (-not $Snapshot -and -not $UiTest) { $timer.Start() }
})

if ($Snapshot -or $UiTest) {
    $form.StartPosition = 'Manual'
    $form.Location = New-Object Drawing.Point(-6000, 0)
    $form.ShowInTaskbar = $false
}

if ($Snapshot) {
    $form.Add_Shown({
        foreach ($row in $gridApps.Rows) { if ("$($row.Cells['AiTools'].Value)") { $gridApps.CurrentCell = $row.Cells['App']; break } }
        if ($Collapsed) { Set-ProcsCollapsed $true }
        [Windows.Forms.Application]::DoEvents()
        $bmp = New-Object Drawing.Bitmap($form.Width, $form.Height)
        $form.DrawToBitmap($bmp, (New-Object Drawing.Rectangle(0, 0, $form.Width, $form.Height)))
        $bmp.Save($Snapshot, [Drawing.Imaging.ImageFormat]::Png)
        $bmp.Dispose()
        $form.Close()
    })
}

# 端到端测试：起临时进程，依次用各个按钮和右键菜单的处理逻辑去关它
if ($UiTest) {
    Set-Content -LiteralPath $UiTest -Value '' -Encoding UTF8
    $dummyExe = Join-Path $env:TEMP 'mm-uitest-dummy.exe'
    Copy-Item "$env:SystemRoot\System32\PING.EXE" $dummyExe -Force
    function Write-TestLog([string]$t) { Add-Content -LiteralPath $UiTest -Value $t -Encoding UTF8 }
    function Start-Dummy {
        # 经由一个马上退出的 cmd 启动，让临时进程自成一个“软件”
        Start-Process cmd.exe -ArgumentList "/c start /b `"`" `"$dummyExe`" -n 600 127.0.0.1" -WindowStyle Hidden
        for ($i = 0; $i -lt 20; $i++) {
            Start-Sleep -Milliseconds 250
            $p = Get-Process -Name 'mm-uitest-dummy' -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($p) { return $p.Id }
        }
        throw '临时进程没有启动'
    }
    function Select-Dummy {
        Update-Data
        foreach ($row in $gridApps.Rows) {
            if ("$($row.Cells['Key'].Value)" -like '*mm-uitest-dummy.exe') { $gridApps.CurrentCell = $row.Cells['App']; return $row }
        }
        $null
    }
    function Select-DummyProc([int]$id) {
        foreach ($row in $gridProcs.Rows) { if ([int]$row.Cells['Pid'].Value -eq $id) { $gridProcs.CurrentCell = $row.Cells['Proc']; return $true } }
        $false
    }
    function Test-Alive([int]$id) { [bool](Get-Process -Id $id -ErrorAction SilentlyContinue) }
    function Check([string]$name, [bool]$ok) { Write-TestLog ("{0} {1}" -f $(if ($ok) { '[通过]' } else { '[失败]' }), $name) }
    $form.Add_Shown({
        try {
            $id = Start-Dummy
            $row = Select-Dummy
            Check '临时进程显示为一个「应用」' ($row -and "$($row.Cells['Kind'].Value)" -eq '应用')
            Check '临时进程有图标' ($row -and $row.Cells['Icon'].Value -and $row.Cells['Icon'].Value -ne $script:BlankIcon)
            Check '临时进程那一行的「AI 后台小工具」是空的' ($row -and -not "$($row.Cells['AiTools'].Value)")
            $wsSum = ($script:Snap.Groups | Measure-Object Ws -Sum).Sum
            Check ('「实际占用」用的是专用工作集，各软件加起来 {0:N1} GB 不超过物理内存已用 {1:N1} GB' -f ($wsSum / 1GB), ($script:Snap.PhysUsed / 1GB)) ($script:Snap.PrivateWs -and $wsSum -le $script:Snap.PhysUsed * 1.02)
            $visibleKinds = @($gridApps.Rows | ForEach-Object { "$($_.Cells['Kind'].Value)" })
            Check '本工具自己那一行默认不显示' ($visibleKinds -notcontains '本工具')
            Check "窗口标题显示预订百分比：$($form.Text)" ($form.Text -like '*已预订*%')
            $btnCloseAi.PerformClick()
            Check '「只关 AI 后台小工具」对没有小工具的程序只提示不关' (Test-Alive $id)

            $txtSearch.Text = 'Ping'
            $names = @($gridApps.Rows | ForEach-Object { "$($_.Cells['App'].Value)" })
            Check "搜索「Ping」只剩匹配的软件（$($names.Count) 个）" ($names.Count -ge 1 -and -not ($names | Where-Object { $_ -notlike '*Ping*' }))
            # 软件名里没有 uitest，进程名里有：应该也能搜到，并且下表把那个进程标黄
            $txtSearch.Text = 'uitest'
            $hitRow = $null
            foreach ($r in $gridApps.Rows) { if ("$($r.Cells['Key'].Value)" -like '*mm-uitest-dummy.exe') { $hitRow = $r } }
            Check "按进程名搜「uitest」能找到临时进程所在的软件（上表剩 $($gridApps.Rows.Count) 行）" ([bool]$hitRow)
            if ($hitRow) { $gridApps.CurrentCell = $hitRow.Cells['App'] }
            $procRow = $null
            foreach ($r in $gridProcs.Rows) { if ([int]$r.Cells['Pid'].Value -eq $id) { $procRow = $r } }
            Check '下表里搜索命中的进程标成黄色' ($procRow -and $procRow.DefaultCellStyle.BackColor -eq $SearchHit)
            $txtSearch.Text = "a'[b%"
            Check '搜索特殊字符不报错' $true
            $txtSearch.Text = ''

            # 下表收起 / 展开
            [Windows.Forms.Application]::DoEvents()
            $h0 = $split.Panel2.Height
            $rows0 = $gridApps.DisplayedRowCount($false)
            $btnToggle.PerformClick(); [Windows.Forms.Application]::DoEvents()
            $rows1 = $gridApps.DisplayedRowCount($false)
            Check "点「收起进程列表」后下表只剩标题栏（高 $h0 → $($split.Panel2.Height)，上表能看到的行 $rows0 → $rows1）" ($split.Panel2.Height -le $split.Panel2MinSize + 2 -and $rows1 -gt $rows0)
            Check "收起后按钮变成「$($btnToggle.Text)」" ($btnToggle.Text -like '*展开*')
            $btnToggle.PerformClick(); [Windows.Forms.Application]::DoEvents()
            Check "点「展开」后恢复原来的高度（$h0 → $($split.Panel2.Height)）" ([math]::Abs($split.Panel2.Height - $h0) -le 3)
            $split.SplitterDistance = Get-CollapsedDistance; [Windows.Forms.Application]::DoEvents()
            Check "把分隔线拖到最底下也算收起（按钮：$($btnToggle.Text)）" ($script:ProcsCollapsed -and $btnToggle.Text -like '*展开*')
            $btnToggle.PerformClick(); [Windows.Forms.Application]::DoEvents()
            Check "拖到底以后点「展开」能恢复（$h0 → $($split.Panel2.Height)）" ([math]::Abs($split.Panel2.Height - $h0) -le 3)
            $form.Height += S 60; [Windows.Forms.Application]::DoEvents()
            Set-ProcsCollapsed $true; $form.Height -= S 60; [Windows.Forms.Application]::DoEvents()
            Check "收起时改变窗口大小仍然贴底（下表高 $($split.Panel2.Height)）" ($split.Panel2.Height -le $split.Panel2MinSize + 2)
            Set-ProcsCollapsed $false; [Windows.Forms.Application]::DoEvents()

            $tblProcs.Rows | Where-Object { $_.Pid -eq $id } | ForEach-Object { $_.Sel = $true }
            $btnCloseProcs.PerformClick()
            Check '「结束勾选的进程」结束了临时进程' (-not (Test-Alive $id))

            $id = Start-Dummy
            [void](Select-Dummy)
            $tblApps.Rows | Where-Object { $_.Key -like '*mm-uitest-dummy.exe' } | ForEach-Object { $_.Sel = $true }
            $btnCloseApps.PerformClick()
            Check '「关闭勾选的软件」结束了临时进程' (-not (Test-Alive $id))

            $btnCloseApps.PerformClick()
            Check '什么都没勾选时只提示（见上一行弹窗）' $true

            $id = Start-Dummy
            [void](Select-Dummy)
            $miAppClose.PerformClick()
            Check '右键「关闭这个软件」结束了临时进程' (-not (Test-Alive $id))

            $id = Start-Dummy
            [void](Select-Dummy)
            Check '下表能选中临时进程' (Select-DummyProc $id)
            $miProcEnd.PerformClick()
            Check '右键「结束这个进程」结束了临时进程' (-not (Test-Alive $id))

            # 快捷键
            Invoke-Shortcut (New-Object Windows.Forms.KeyEventArgs(([Windows.Forms.Keys]::Control -bor [Windows.Forms.Keys]::F)))
            Check 'Ctrl+F 跳到搜索框' ($txtSearch.Focused -or $form.ActiveControl -eq $txtSearch)
            $txtSearch.Text = 'abc'
            Invoke-Shortcut (New-Object Windows.Forms.KeyEventArgs([Windows.Forms.Keys]::Escape))
            Check 'Esc 清空搜索框' (-not $txtSearch.Text)
            $t0 = $script:Snap.Taken; Start-Sleep -Milliseconds 1100
            Invoke-Shortcut (New-Object Windows.Forms.KeyEventArgs([Windows.Forms.Keys]::F5))
            Check 'F5 刷新列表' ($script:Snap.Taken -gt $t0)
            $id = Start-Dummy
            [void](Select-Dummy)
            [void]$gridApps.Focus()
            Invoke-Shortcut (New-Object Windows.Forms.KeyEventArgs([Windows.Forms.Keys]::Space))
            $sel1 = [bool]($tblApps.Rows | Where-Object { $_.Key -like '*mm-uitest-dummy.exe' } | Select-Object -First 1).Sel
            Invoke-Shortcut (New-Object Windows.Forms.KeyEventArgs([Windows.Forms.Keys]::Space))
            $sel2 = [bool]($tblApps.Rows | Where-Object { $_.Key -like '*mm-uitest-dummy.exe' } | Select-Object -First 1).Sel
            Check "空格勾上、再按一次取消（$sel1 → $sel2）" ($sel1 -and -not $sel2)
            Invoke-Shortcut (New-Object Windows.Forms.KeyEventArgs([Windows.Forms.Keys]::Space))
            Invoke-Shortcut (New-Object Windows.Forms.KeyEventArgs([Windows.Forms.Keys]::Delete))
            Check 'Delete 关掉勾选的软件' (-not (Test-Alive $id))
            Check '关掉临时进程后没有误报「又被拉起来」' (-not (Select-String -LiteralPath $UiTest -Pattern '马上又自己启动了' -Quiet))

            # 切回窗口时自动刷新：列表旧了、没勾选 → 刷新；有勾选 → 不刷新
            $script:Snap.Taken = (Get-Date).AddMinutes(-5)
            [void](Invoke-AutoRefresh)
            Check '列表超过 1 分钟、没有勾选时，切回窗口会自动刷新' (((Get-Date) - $script:Snap.Taken).TotalSeconds -lt 30)
            $tblApps.Rows[0].Sel = $true
            $script:Snap.Taken = (Get-Date).AddMinutes(-5)
            [void](Invoke-AutoRefresh)
            Check '有勾选时不自动刷新（免得清掉勾选）' (((Get-Date) - $script:Snap.Taken).TotalSeconds -gt 200)
            $tblApps.Rows[0].Sel = $false

            # 带守护进程的软件：关掉后被别的进程马上拉起来，应该提示
            $watchdog = Start-Job -ArgumentList $dummyExe -ScriptBlock {
                param($exe)
                $deadline = (Get-Date).AddSeconds(40)
                while ((Get-Date) -lt $deadline) {
                    if (-not (Get-Process -Name 'mm-uitest-dummy' -ErrorAction SilentlyContinue)) {
                        Start-Process cmd.exe -ArgumentList "/c start /b `"`" `"$exe`" -n 600 127.0.0.1" -WindowStyle Hidden
                    }
                    Start-Sleep -Milliseconds 200
                }
            }
            $id = $null
            for ($i = 0; $i -lt 40 -and -not $id; $i++) { Start-Sleep -Milliseconds 250; $id = (Get-Process -Name 'mm-uitest-dummy' -ErrorAction SilentlyContinue | Select-Object -First 1).Id }
            [void](Select-Dummy)
            $miAppClose.PerformClick()
            Check '关掉后马上被守护进程拉起来的软件，会提示「又自己启动了」' ([bool](Select-String -LiteralPath $UiTest -Pattern '马上又自己启动了' -Quiet))
            Stop-Job $watchdog; Remove-Job $watchdog -Force
            Get-Process -Name 'mm-uitest-dummy' -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue

            # 只关旧的 AI 小工具：按钮状态要和统计一致
            $staleNow = ($script:AiSummary | ForEach-Object { $_.Stale.Count } | Measure-Object -Sum).Sum + 0
            Check "「只关开了 $StaleHours 小时以上的」按钮状态和统计一致（$staleNow 个，按钮$(if ($btnStaleAi.Enabled) { '可点' } else { '灰着' })）" ($btnStaleAi.Enabled -eq ($staleNow -gt 0))
            # 把阈值临时调成 3 秒，让现有的 AI 小工具都算“旧的”，走一遍按钮流程；测试里回答“否”，不真的关
            $savedHours = $StaleHours
            $script:StaleHours = 0.001
            Update-Data
            $stalePids = @($script:AiSummary | ForEach-Object { $_.Stale } | ForEach-Object { [int]$_.Pid })
            $aiCount = ($script:AiSummary | ForEach-Object { $_.Targets.Count } | Measure-Object -Sum).Sum + 0
            Check "阈值调成 3 秒后，AI 小工具都算旧的（旧 $($stalePids.Count) 个 / 共 $aiCount 个），按钮可点" ($btnStaleAi.Enabled -and $stalePids.Count -eq $aiCount -and $aiCount -gt 0)
            $script:TestAnswers.Enqueue('No')
            $btnStaleAi.PerformClick()
            Check '「只关旧的」弹出了确认，选「否」时什么都不关' ((Select-String -LiteralPath $UiTest -Pattern '\[弹窗：关闭旧的 AI 后台小工具\] 将要结束' -Quiet) -and @($stalePids | Where-Object { Test-Alive $_ }).Count -ge $stalePids.Count - 1)
            $script:StaleHours = $savedHours
            Update-Data

            # 全部 AI 小工具：测试里回答“否”，只看确认内容，不真的关
            $aiPids = @($script:AiSummary | ForEach-Object { $_.Targets } | ForEach-Object { [int]$_.Pid })
            $script:TestAnswers.Enqueue('No')
            $btnAllAi.PerformClick()
            $stillAlive = @($aiPids | Where-Object { Test-Alive $_ }).Count
            Check "「一键关闭全部 AI 后台小工具」选「否」时什么都不关（$($aiPids.Count) 个里还在 $stillAlive 个）" ($stillAlive -ge [math]::Max(0, $aiPids.Count - 2))

            Update-Header (Get-MemTotals)
            Check "顶部实时数字能刷新：$($lblCommit.Text)" ([bool]$lblCommit.Text)
            Write-TestLog "AI 汇总：$($lblAi.Text)"
        } catch {
            Write-TestLog "[失败] 异常：$($_.Exception.Message)（第 $($_.InvocationInfo.ScriptLineNumber) 行）"
        } finally {
            Get-Process -Name 'mm-uitest-dummy' -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
            Start-Sleep -Milliseconds 300
            Remove-Item $dummyExe -Force -ErrorAction SilentlyContinue
            $form.Close()
        }
    })
}

[void]$form.ShowDialog()
