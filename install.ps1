# lightdrop installer for Windows (PowerShell):
#   irm https://gist.githubusercontent.com/yakubmurcek/7cc69d2af1db4b710846e113a69fcae2/raw/install.ps1 | iex
# Downloads the binary and starts the background receiver (asks for admin once,
# for the firewall rule and the startup task).
$ErrorActionPreference = 'Stop'
$base = 'https://gist.githubusercontent.com/yakubmurcek/7cc69d2af1db4b710846e113a69fcae2/raw'
$tmp = Join-Path $env:TEMP 'lightdrop-setup.exe'
Invoke-WebRequest -UseBasicParsing -OutFile $tmp "$base/lightdrop-windows-amd64.exe"
& $tmp install
Remove-Item $tmp -EA SilentlyContinue
