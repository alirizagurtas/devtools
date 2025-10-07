# === WSL Kontrolü ===
$distros = wsl --list --quiet 2>$null
if ($LASTEXITCODE -ne 0) {
    Write-Host "❌ WSL yüklü değil! 'wsl --install' komutuyla kurun." -ForegroundColor Red
    exit
}

# === Ayarlar ===
$distroName = "Ubuntu-24.04"
$folderPath = "C:\wsl-backup-images\backups"
$timestamp  = Get-Date -Format "dd_MM_yyyy_HH-mm"
$fileName   = "$distroName-$timestamp.tar"
$exportPath = Join-Path $folderPath $fileName

# === Klasör oluştur ===
if (!(Test-Path $folderPath)) {
    New-Item -ItemType Directory -Path $folderPath | Out-Null
}

# === Dosya varsa sor ===
if (Test-Path $exportPath) {
    Write-Host "⚠️ Mevcut: $fileName" -ForegroundColor Yellow
    Write-Host -NoNewline "Yeni ad (Enter=üzerine yaz): "
    $input = Read-Host
    
    if ($input) {
        $fileName = if ($input.EndsWith(".tar")) { $input } else { "$input.tar" }
        $exportPath = Join-Path $folderPath $fileName
    }
    
    if (Test-Path $exportPath) { Remove-Item $exportPath -Force }
}

# === Dışa aktar ===
Write-Host "⏳ Dışa aktarılıyor..." -ForegroundColor Green
wsl --export $distroName $exportPath

if ($LASTEXITCODE -eq 0) {
    Write-Host "✅ Image başarıyla yedeklendi: $exportPath" -ForegroundColor Green
} else {
    Write-Host "❌ Hata!" -ForegroundColor Red
}
