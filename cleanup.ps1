<#
Algoritmika Python installer helper (Windows PowerShell 5.1, run elevated).
  -Phase pre        remove old Algoritmika Python and every registered Python install
  -Phase post       make sure our python is on the machine PATH, exit 1 if `python` resolves elsewhere
  -Phase uninstall  take our entries back off the machine PATH
Add -WhatIf to list what would be removed without touching anything.
Only registered installs and their default folders are touched: apps that bundle
their own python (Blender, LibreOffice, QGIS...) are left alone on purpose.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)][ValidateSet('pre', 'post', 'uninstall')][string]$Phase,
    [string]$AppDir = "$env:ProgramFiles\Algoritmika"
)

Start-Transcript "$env:TEMP\algopython-$Phase.log" -WhatIf:$false | Out-Null

$AlgoName = '(?i)algoritmika|algopython|algovscode'
$PythonName = '(?i)^(python (\d|launcher|install manager)|anaconda|miniconda|miniforge)'
# registry-reported folders are deleted only if their own name looks like one of these
$SafeLeaf = '(?i)^(algoritmika|c?python|anaconda|miniconda|miniforge)'
$MachineEnv = 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Environment'
$Ours = "$AppDir\python", "$AppDir\python\Scripts"

# HKCU belongs to whoever approved UAC, not necessarily the student: walk every loaded user hive
$UserHives = Get-ChildItem Registry::HKEY_USERS -ErrorAction SilentlyContinue | Where-Object PSChildName -match '^S-1-5-21-[\d-]+$' |
    ForEach-Object { "Registry::HKEY_USERS\$($_.PSChildName)" }

function Edit-Path([string]$Key, [scriptblock]$Change) {
    $item = Get-Item $Key -ErrorAction SilentlyContinue
    if (-not $item) { return }
    # raw read keeps %SystemRoot%-style entries unexpanded
    $old = @($item.GetValue('Path', '', 'DoNotExpandEnvironmentNames') -split ';' | Where-Object { $_ })
    $new = @(& $Change $old)
    if (($new -join ';') -eq ($old -join ';')) { return }
    Compare-Object $old $new | ForEach-Object { "PATH $($_.SideIndicator) $($_.InputObject)   [$Key]" }
    Set-ItemProperty $Key -Name Path -Value ($new -join ';') -Type ExpandString
}

function Split-Command([string]$s) {
    if ($s -match '^\s*"([^"]+)"\s*(.*)$' -or $s -match '^\s*(\S+)\s*(.*)$') { $Matches[1], $Matches[2] }
}

function Invoke-Uninstall($e) {
    if (-not (Test-Path $e.PSPath)) { return }  # already gone with its parent bundle
    if ($e.WindowsInstaller -eq 1) { $exe = 'msiexec.exe'; $arg = "/x $($e.PSChildName) /qn /norestart" }
    elseif ($e.PSChildName -like '*_is1') { $exe = (Split-Command $e.UninstallString)[0]; $arg = '/VERYSILENT /SUPPRESSMSGBOXES /NORESTART' }
    elseif ($e.QuietUninstallString) { $exe, $arg = Split-Command $e.QuietUninstallString }
    else { "no silent uninstaller, removing files only: $($e.DisplayName)"; return }
    if ($WhatIfPreference) { "What if: uninstall '$($e.DisplayName)' via $exe $arg"; return }
    "uninstalling $($e.DisplayName)"
    $p = Start-Process $exe -ArgumentList "$arg " -PassThru -WindowStyle Hidden
    # 10 min cap so one stuck uninstaller can't hang setup; its files are wiped below anyway
    if (-not $p.WaitForExit(600000)) { $p.Kill(); "timed out: $($e.DisplayName)" }
}

if ($Phase -eq 'pre') {
    $roots = @('HKLM:\SOFTWARE', 'HKLM:\SOFTWARE\WOW6432Node') + @($UserHives | ForEach-Object { "$_\Software" })

    $entries = $roots | ForEach-Object { Get-ItemProperty "$_\Microsoft\Windows\CurrentVersion\Uninstall\*" -ErrorAction SilentlyContinue } |
        Where-Object { "$($_.DisplayName) $($_.Publisher)" -match $AlgoName -or $_.DisplayName -match $PythonName }
    $installDirs = @($entries.InstallLocation) +
        @($roots | ForEach-Object { Get-Item "$_\Python\*\*\InstallPath" -ErrorAction SilentlyContinue } | ForEach-Object { $_.GetValue('') })

    # running editors / interpreters keep files locked
    Get-Process | Where-Object { $_.Path -match '(?i)\\(algoritmika|python\d+|anaconda3|miniconda3|miniforge3)\\|\\programs\\python\\' } |
        Stop-Process -Force

    # MSI parts last: a python.org bundle removes its own MSIs
    $entries | Sort-Object { [int]$_.WindowsInstaller } | ForEach-Object { Invoke-Uninstall $_ }

    Get-AppxPackage -AllUsers -Name 'PythonSoftwareFoundation.*' -ErrorAction SilentlyContinue | ForEach-Object {
        if ($WhatIfPreference) { "What if: remove Store app $($_.PackageFullName)" }
        else { Remove-AppxPackage $_.PackageFullName -AllUsers }
    }

    # leftovers: registry
    $entries | Where-Object { Test-Path $_.PSPath } | ForEach-Object { Remove-Item $_.PSPath -Recurse -Force }
    $roots | ForEach-Object { "$_\Python" } | Where-Object { Test-Path $_ } | Remove-Item -Recurse -Force

    # leftovers: files
    $profiles = (Get-ChildItem "$env:SystemDrive\Users" -Directory).FullName
    $start = 'Microsoft\Windows\Start Menu\Programs'
    $globs = @(
        "$env:ProgramFiles\Algoritmika", "${env:ProgramFiles(x86)}\Algoritmika",
        "$env:ProgramFiles\Python[0-9]*", "${env:ProgramFiles(x86)}\Python[0-9]*", "$env:SystemDrive\Python[0-9]*",
        "$env:ProgramData\anaconda3", "$env:ProgramData\miniconda3", "$env:ProgramData\miniforge3",
        "$env:ProgramData\$start\Algoritmika", "$env:ProgramData\$start\Python *", "$env:ProgramData\$start\Anaconda*",
        "$env:SystemRoot\py.exe", "$env:SystemRoot\pyw.exe"
    ) + @($profiles | ForEach-Object {
        "$_\AppData\Local\Programs\Algoritmika", "$_\AppData\Local\Programs\Python", "$_\AppData\Local\Python",
        "$_\AppData\Roaming\Python", "$_\AppData\Local\pip", "$_\anaconda3", "$_\miniconda3", "$_\miniforge3",
        "$_\.conda", "$_\.condarc",
        "$_\AppData\Roaming\uv\python", "$_\.local\bin\python*.exe",  # uv-managed pythons and their shims, uv itself stays
        "$_\AppData\Roaming\$start\Algoritmika", "$_\AppData\Roaming\$start\Python *", "$_\AppData\Roaming\$start\Anaconda*"
    }) + @($installDirs | Where-Object { $_ } | ForEach-Object { $_.TrimEnd('\') } | Where-Object { (Split-Path $_ -Leaf) -match $SafeLeaf })
    Get-Item ($globs | Where-Object { $_ } | Sort-Object -Unique) -Force -ErrorAction SilentlyContinue | Remove-Item -Recurse -Force

    $shell = New-Object -ComObject WScript.Shell
    Get-ChildItem ($profiles | ForEach-Object { "$_\Desktop\*.lnk", "$_\OneDrive*\*\*.lnk" }) -Force -ErrorAction SilentlyContinue |
        Where-Object { $shell.CreateShortcut($_.FullName).TargetPath -match $AlgoName } | Remove-Item -Force

    # leftovers: PATH (machine + every logged-in user). Matched by name, not by "has python.exe":
    # shared dirs like WindowsApps or ~\.local\bin hold python shims next to unrelated tools.
    # `python` still resolves to ours because post prepends it to the machine PATH.
    $isPython = '(?i)\\python\d*(\\scripts|\\bin)?\\?$|\\programs\\python\\|anaconda|miniconda|miniforge|algoritmika'
    foreach ($k in @($MachineEnv) + @($UserHives | ForEach-Object { "$_\Environment" })) {
        Edit-Path $k { param($p) $p | Where-Object { $_ -notmatch $isPython } }
    }
}

if ($Phase -eq 'post') {
    Edit-Path $MachineEnv { param($p) @($Ours | Where-Object { $p -notcontains $_ }) + $p }
    $env:Path = (@($MachineEnv, 'HKCU:\Environment') | ForEach-Object { (Get-ItemProperty $_ -ErrorAction SilentlyContinue).Path }) -join ';'
    $found = (Get-Command python.exe -ErrorAction SilentlyContinue | Select-Object -First 1).Source
    "python resolves to: $found"
    if ($found -ne "$AppDir\python\python.exe") { Stop-Transcript | Out-Null; exit 1 }
}

if ($Phase -eq 'uninstall') {
    Edit-Path $MachineEnv { param($p) $p | Where-Object { $Ours -notcontains $_ } }
}

Stop-Transcript | Out-Null
