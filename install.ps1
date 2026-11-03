# lightdrop installer for Windows (PowerShell):
#   irm https://github.com/yakubmurcek/lightdrop/releases/latest/download/install.ps1 | iex
# Downloads the binary and starts the background receiver (asks for admin once,
# for the firewall rule and the startup task).
$ErrorActionPreference = 'Stop'
$base = 'https://github.com/yakubmurcek/lightdrop/releases/latest/download'
$tmp = Join-Path $env:TEMP 'lightdrop-setup.exe'
Invoke-WebRequest -UseBasicParsing -OutFile $tmp "$base/lightdrop-windows-amd64.exe"
& $tmp install
Remove-Item $tmp -EA SilentlyContinue
