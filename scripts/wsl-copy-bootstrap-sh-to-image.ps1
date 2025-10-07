# === Ayarlar ===
$File    = "bootstrap-controller.sh"
$Distro  = "Ubuntu-24.04"
$RawUrl  = "https://raw.githubusercontent.com/alirizagurtas/devtools/main/scripts/bootstrap/$File"

# === Dosyayı temp'e indir ===
$Tmp = Join-Path $env:TEMP $File
Invoke-WebRequest -Uri $RawUrl -OutFile $Tmp -UseBasicParsing

# === Mevcut bootstrap klasörünü tamamen sil ve yeniden oluştur ===
wsl -d $Distro bash -lc "sudo rm -rf ~/bootstrap && mkdir -p ~/bootstrap"

# === Dosyayı WSL /tmp'ye kopyala ===
Copy-Item $Tmp "\\wsl.localhost\$Distro\tmp\$File" -Force

# === WSL içinde dosyayı kopyala, satır sonlarını düzelt ve çalıştırılabilir yap ===
wsl -d $Distro bash -lc "cp /tmp/$File ~/bootstrap/$File && sed -i 's/\r$//' ~/bootstrap/$File && chmod +x ~/bootstrap/$File"

# === Sahipliği kontrol et ===
Write-Host "🔍 Dosya sahipliği kontrol ediliyor..." -ForegroundColor Cyan
wsl -d $Distro bash -lc "ls -lah ~/bootstrap/$File"

# === Nereye kopyalandığını ve nasıl çalıştırılacağını göster ===
Write-Host ""
Write-Host "✅ Dosya kopyalandı ve izinler ayarlandı!" -ForegroundColor Green
Write-Host ""
Write-Host "💡 Çalıştırmak için:" -ForegroundColor Yellow
Write-Host "   wsl -d $Distro bash -lc '~/bootstrap/$File'" -ForegroundColor White
