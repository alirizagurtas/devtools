# === Ayarlar ===
$folderPath = "C:\wsl-backup-images"
$fileName   = "ubuntu-controller-image.tar"
$importPath = Join-Path $folderPath $fileName
$installDir = "C:\wsl\ubuntu"
$distName   = "Ubuntu-24.04"

# === Dosya kontrolü ===
if (!(Test-Path $importPath)) {
    Write-Host "Dosya bulunamadı: $importPath"
    exit
}

# === Klasör yoksa oluştur ===
if (!(Test-Path $installDir)) {
    New-Item -ItemType Directory -Path $installDir | Out-Null
}

# === Dağıtım zaten varsa onay iste ===
$existing = wsl --list --quiet | Select-String "^$distName$"
if ($existing) {
    $response = Read-Host "Dağıtım '$distName' zaten var. Silip yeniden yüklemek istiyor musun? (E/H)"
    if ($response -notin @('E','e')) {
        Write-Host "İşlem iptal edildi."
        exit
    }
    wsl --unregister $distName
}

# === WSL import işlemi ===
wsl --import $distName $installDir $importPath --version 2

Write-Host "✅ Geri yükleme tamamlandı: $distName (konum: $installDir)"
