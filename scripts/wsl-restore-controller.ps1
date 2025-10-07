# === WSL Kontrolü ===
$distros = wsl --list --quiet 2>$null
if ($LASTEXITCODE -ne 0) {
    Write-Host "❌ WSL yüklü değil! 'wsl --install' komutuyla kurun." -ForegroundColor Red
    exit
}

# === Ayarlar ===
$folderPath = "C:\wsl-backup-images\backups"

# === Klasör kontrolü ===
if (!(Test-Path $folderPath)) {
    Write-Host "❌ Yedek klasörü bulunamadı: $folderPath" -ForegroundColor Red
    exit
}

# === Yedek dosyalarını listele ===
$backupFiles = Get-ChildItem -Path $folderPath -Filter "*.tar" | Sort-Object LastWriteTime -Descending

if ($backupFiles.Count -eq 0) {
    Write-Host "❌ Hiç yedek dosyası bulunamadı!" -ForegroundColor Red
    exit
}

Write-Host "📋 Mevcut yedekler:" -ForegroundColor Cyan
for ($i = 0; $i -lt $backupFiles.Count; $i++) {
    $size = [math]::Round($backupFiles[$i].Length / 1MB, 2)
    Write-Host "  [$($i+1)] $($backupFiles[$i].Name) ($size MB)" -ForegroundColor White
}

Write-Host ""
Write-Host -NoNewline "Hangi yedeği geri yüklemek istersiniz? (1-$($backupFiles.Count)): "
$selection = Read-Host

if ($selection -match '^\d+$' -and [int]$selection -ge 1 -and [int]$selection -le $backupFiles.Count) {
    $selectedBackup = $backupFiles[[int]$selection - 1]
} else {
    Write-Host "❌ Geçersiz seçim!" -ForegroundColor Red
    exit
}

# === Dosya adını aynen kullan (.tar hariç) ===
$distroName = $selectedBackup.Name -replace '\.tar$', ''

# === Dağıtım zaten var mı kontrol et ===
$existingDistros = wsl --list --quiet | ForEach-Object { $_.Trim() -replace '\x00', '' }
if ($existingDistros -contains $distroName) {
    Write-Host "⚠️ '$distroName' zaten mevcut!" -ForegroundColor Yellow
    Write-Host -NoNewline "Üzerine yazmak ister misiniz? (E/H): "
    $confirm = Read-Host
    
    if ($confirm -eq 'E' -or $confirm -eq 'e') {
        Write-Host "🗑️ Mevcut dağıtım siliniyor..." -ForegroundColor Yellow
        wsl --unregister $distroName
    } else {
        Write-Host "❌ İşlem iptal edildi!" -ForegroundColor Red
        exit
    }
}

# === Geri yükleme klasörünü oluştur ===
$installPath = "C:\wsl-distros\$distroName"
if (!(Test-Path $installPath)) {
    New-Item -ItemType Directory -Path $installPath -Force | Out-Null
}

# === Geri yükle ===
Write-Host ""
Write-Host "⏳ Geri yükleniyor..." -ForegroundColor Green
Write-Host "   Yedek dosyası: $($selectedBackup.Name)" -ForegroundColor Gray
Write-Host "   Restore konumu: $installPath" -ForegroundColor Gray
Write-Host ""

wsl --import $distroName $installPath $selectedBackup.FullName

if ($LASTEXITCODE -eq 0) {
    Write-Host ""
    Write-Host "✅ Geri yükleme tamamlandı!" -ForegroundColor Green
    Write-Host "   Dağıtım adı: $distroName" -ForegroundColor Cyan
    Write-Host "   Restore konumu: $installPath" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "💡 Kullanım:" -ForegroundColor Yellow
    Write-Host "   Başlatmak için: wsl -d $distroName" -ForegroundColor White
    Write-Host "   Varsayılan yapmak için: wsl --set-default $distroName" -ForegroundColor White
} else {
    Write-Host "❌ Geri yükleme başarısız!" -ForegroundColor Red
}
