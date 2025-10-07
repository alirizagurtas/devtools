# --- Settings ---
$File    = "bootstrap-controller.sh"
$Distro  = "Ubuntu-24.04"       # wsl -l -q ile ismini doğrula
$RawUrl  = "https://raw.githubusercontent.com/alirizagurtas/devtools/main/scripts/bootstrap/$File"


# --- Resolve WSL $HOME as a Windows path ---
$WinHome = (wsl -d $Distro wslpath -w ~).Trim()
New-Item -ItemType Directory -Path $WinHome -Force | Out-Null

# --- Download to temp, then copy into WSL home ---
$Tmp = Join-Path $env:TEMP $File
Invoke-WebRequest -Uri $RawUrl -OutFile $Tmp -UseBasicParsing
Copy-Item $Tmp (Join-Path $WinHome $File) -Force

# --- Fix line endings + make executable inside WSL ---
wsl -d $Distro bash -lc "sed -i 's/\r$//' ~/$File && chmod +x ~/$File"

# --- Optional: show where it landed and how to run ---
Write-Host "Copied to: $WinHome\$File"
Write-Host "Run it with:" 
Write-Host "wsl -d $Distro bash -lc '~/bootstrap/$File'"
