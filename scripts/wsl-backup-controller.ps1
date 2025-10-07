# === Ayarlar ===
$folderPath = "C:\wsl-backup-images"
$fileName   = "ubuntu-controller-image.tar"
$exportPath = Join-Path $folderPath $fileName

# === Klasör yoksa oluştur ===
if (!(Test-Path $folderPath)) {
    New-Item -ItemType Directory -Path $folderPath | Out-Null
}

# === Dosya varsa onay iste ===
if (Test-Path $exportPath) {
    $response = Read-Host "Dosya '$fileName' zaten var. Üzerine yazmak istiyor musun? (E/H)"
    if ($response -notin @('E','e')) {
        Write-Host "İşlem iptal edildi."
        exit
    }
    Remove-Item $exportPath -Force
}

# === WSL dışa aktar ===
wsl --export Ubuntu-24.04 $exportPath
Write-Host "Dışa aktarma tamamlandı: $exportPath"
