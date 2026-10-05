#Requires -Version 7.4
<#
Builds the Algoritmika Python installer into Output\algopython-<ver>.exe.   pwsh -File build.ps1

Needs internet. Everything lands in this folder; nothing stays installed on the build
machine (Python goes to .staging, gets copied, then uninstalled).
Libraries come from requirements.lock. To change them: edit requirements.in, run
build.ps1 -Resolve (rewrites requirements.lock), check smoke_test.py output.
#>
param([switch]$Resolve)
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true

$PyVer = '3.13.16'
$CodeVer = '1.140.0'
$InnoVer = '6.7.3'
$Final = 'C:\Program Files\Algoritmika\python'  # also hardcoded in vscode-settings.json and algopython.iss
$Algo = 'algovscode.algoritmika-python-20250904.95201.0.vsix'

$root = $PSScriptRoot
$env:TEMP = $env:TMP = "$root\.tmp"  # tensorflow alone unpacks to ~1.5 GB; keep it off C:
$env:PIP_CACHE_DIR = "$root\.cache\pip"
$env:PIP_DISABLE_PIP_VERSION_CHECK = '1'
New-Item -ItemType Directory -Force "$root\downloads", "$root\.tmp" | Out-Null

function Get-Download($url, $name) {
    $f = "$root\downloads\$name"
    if (-not (Test-Path $f)) { Invoke-WebRequest $url -OutFile $f }
    if ($f -like '*.exe' -and (Get-AuthenticodeSignature $f).Status -ne 'Valid') { throw "bad signature: $f" }
    $f
}

$pyExe = Get-Download "https://www.python.org/ftp/python/$PyVer/python-$PyVer-amd64.exe" "python-$PyVer-amd64.exe"
$codeZip = Get-Download "https://update.code.visualstudio.com/$CodeVer/win32-x64-archive/stable" "VSCode-win32-x64-$CodeVer.zip"
$innoExe = Get-Download "https://github.com/jrsoftware/issrc/releases/download/is-$($InnoVer -replace '\.', '_')/innosetup-$InnoVer.exe" "innosetup-$InnoVer.exe"
$iscc = "$root\tools\innosetup\ISCC.exe"
if (-not (Test-Path $iscc)) {
    Start-Process $innoExe "/VERYSILENT /SUPPRESSMSGBOXES /NORESTART /CURRENTUSER /PORTABLE=1 /NOICONS /DIR=`"$root\tools\innosetup`"" -Wait
}

if (Test-Path "$root\build") { Remove-Item "$root\build" -Recurse -Force }
New-Item -ItemType Directory "$root\build" | Out-Null

# --- Python: the NuGet package has no tkinter (no turtle), so use the real installer and copy it out
Start-Process $pyExe "/quiet InstallAllUsers=0 TargetDir=`"$root\.staging\python`" Include_launcher=0 InstallLauncherAllUsers=0 Shortcuts=0 AssociateFiles=0 PrependPath=0 Include_test=0 Include_doc=0 Include_debug=0 Include_symbols=0 Include_dev=1 Include_tcltk=1 Include_pip=1 CompileAll=0" -Wait
Copy-Item "$root\.staging\python" "$root\build\python" -Recurse
Start-Process $pyExe '/uninstall /quiet' -Wait
$python = "$root\build\python\python.exe"

if ($Resolve) {
    & $python -m pip install -r "$root\requirements.in" --prefer-binary --no-warn-script-location
    & $python -m pip freeze --exclude pip | Set-Content "$root\requirements.lock"
} else {
    & $python -m pip install -r "$root\requirements.lock" --prefer-binary --no-warn-script-location
}

# --- One current VC++ runtime for everything. PyQt5 and panda3d ship 2015-2019 copies of msvcp140.dll;
# whichever loads first makes tensorflow's DLL init fail. python.exe's folder is searched before
# add_dll_directory() paths, but a copy next to a library's own .pyd wins over it, so replace those too.
# Taken from this machine's System32 (VC++ 2015-2022 redistributable; app-local copies are allowed).
$sys32 = "$env:SystemRoot\System32"
'msvcp140.dll', 'msvcp140_1.dll', 'msvcp140_2.dll', 'msvcp140_atomic_wait.dll', 'msvcp140_codecvt_ids.dll', 'vcruntime140.dll', 'vcruntime140_1.dll' |
    ForEach-Object { Copy-Item "$sys32\$_" "$root\build\python" -Force }
Get-ChildItem "$root\build\python\Lib\site-packages" -Recurse -File |
    Where-Object { $_.Name -match '^(msvcp140.*|vcruntime140.*|concrt140)\.dll$' -and (Test-Path "$sys32\$($_.Name)") } |
    ForEach-Object { Copy-Item "$sys32\$($_.Name)" $_.FullName -Force }

# --- VS Code in portable mode (data\ next to Code.exe)
New-Item -ItemType Directory "$root\build\vscode" | Out-Null
& "$sys32\tar.exe" -xf $codeZip -C "$root\build\vscode"
$userData = "$root\build\vscode\data\user-data"
New-Item -ItemType Directory -Force "$userData\User" | Out-Null
$code = "$root\build\vscode\bin\code.cmd"
& $code --install-extension "$root\extensions\$Algo"
& $code --install-extension ms-python.python  # pulls debugpy, pylance, python-envs
Copy-Item "$root\vscode-settings.json" "$userData\User\settings.json"
# caches, logs and machineid must not be shipped to every student
Get-ChildItem $userData -Force | Where-Object Name -ne 'User' | Remove-Item -Recurse -Force

# --- check, then point pip's .exe launchers at the install location (they stop working from build\)
& $python "$root\smoke_test.py"
& $python "$root\relocate.py" $Final

& $iscc "/DPyVer=$PyVer" "/DPyTag=$($PyVer -replace '\.\d+$')" "$root\algopython.iss"
Get-ChildItem "$root\Output\*.exe" | Select-Object Name, @{ n = 'MB'; e = { [int]($_.Length / 1MB) } }
