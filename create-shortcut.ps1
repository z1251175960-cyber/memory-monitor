#requires -Version 5.1
# 在桌面创建“内存占用查看”快捷方式，指向同目录的 launch.vbs（不弹黑窗口）。
param(
    [string]$Path = (Join-Path ([Environment]::GetFolderPath('Desktop')) '内存占用查看.lnk')
)

$launcher = Join-Path $PSScriptRoot 'launch.vbs'
if (-not (Test-Path -LiteralPath $launcher)) { throw "找不到 $launcher，请把整个文件夹放在一起" }

$shell = New-Object -ComObject WScript.Shell
$shortcut = $shell.CreateShortcut($Path)
$shortcut.TargetPath = Join-Path $env:SystemRoot 'System32\wscript.exe'
$shortcut.Arguments = '"' + $launcher + '"'
$shortcut.WorkingDirectory = $PSScriptRoot
$shortcut.IconLocation = (Join-Path $env:SystemRoot 'System32\Taskmgr.exe') + ',0'
$shortcut.Description = '按软件分组查看内存占用，勾选后一键关闭'
$shortcut.Save()
"已创建快捷方式：$Path"
