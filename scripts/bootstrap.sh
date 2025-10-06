#!/bin/bash
set -euo pipefail

# === CONFIGURATION ===
readonly SCRIPT_NAME="$(basename "$0")"
readonly VM_NET_CIDR="${VM_NET_CIDR:-10.10.0.0/16}"
readonly ANSIBLE_VERSION="2.19.2"

# === FUNCTIONS ===
log_info() {
    echo "✅ $*"
}

log_step() {
    echo ""
    echo "🔧 $*"
}

# WSL systemd + DNS (systemd-resolved)
configure_wsl_network() {
    log_step "WSL systemd + DNS (systemd-resolved) ayarlanıyor..."
    
    # DNS zaten yapılandırıldı mı kontrol et
    if [[ -f /etc/systemd/resolved.conf.d/dns.conf ]] && \
       [[ -L /etc/resolv.conf ]] && \
       [[ "$(readlink /etc/resolv.conf)" == "/run/systemd/resolve/stub-resolv.conf" ]]; then
        log_info "DNS zaten yapılandırılmış, atlanıyor"
        return
    fi
    
    # WSL config
    sudo tee /etc/wsl.conf >/dev/null <<'EOF'
[boot]
systemd=true
[network]
generateResolvConf=false
EOF

    # systemd-resolved DNS config
    sudo mkdir -p /etc/systemd/resolved.conf.d
    sudo tee /etc/systemd/resolved.conf.d/dns.conf >/dev/null <<'EOF'
[Resolve]
DNS=1.1.1.1 8.8.8.8
FallbackDNS=9.9.9.9
EOF

    # resolv.conf'u systemd-resolved'e bağla
    sudo rm -f /etc/resolv.conf
    sudo ln -sf /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf

    # Servisi etkinleştir ve başlat
    sudo systemctl enable systemd-resolved >/dev/null 2>&1 || true
    sudo systemctl restart systemd-resolved
    
    # DNS'in çalıştığından emin ol (max 10 saniye bekle)
    for i in {1..10}; do
        if ping -c1 -W1 1.1.1.1 >/dev/null 2>&1 && \
           ping -c1 -W1 google.com >/dev/null 2>&1; then
            log_info "DNS yapılandırıldı (systemd-resolved aktif)"
            return
        fi
        sleep 1
    done
    
    log_info "⚠️  DNS yapılandırıldı ama test başarısız - devam ediliyor"
}

# Sistem güncelleme ve temel araçlar
update_system() {
    log_step "Sistem güncelleniyor..."
    sudo apt update -y
    sudo apt install -y ca-certificates curl gnupg net-tools iproute2 nano
}

# Kalıcı route yapılandırması
setup_persistent_route() {
    log_step "Kalıcı route script (WSL -> VM ağı)..."
    
    sudo tee /usr/local/bin/add-route.sh >/dev/null <<EOF
#!/bin/bash
GW=\$(grep -m1 nameserver /etc/resolv.conf | awk '{print \$2}')
sudo ip route add ${VM_NET_CIDR} via "\$GW" 2>/dev/null || true
EOF

    sudo chmod +x /usr/local/bin/add-route.sh
    
    local current_user
    current_user="$(whoami)"
    
    echo "$current_user ALL=(ALL) NOPASSWD: /usr/local/bin/add-route.sh, /usr/sbin/ip" | \
        sudo tee /etc/sudoers.d/99-wsl-route >/dev/null
    sudo chmod 0440 /etc/sudoers.d/99-wsl-route
    
    echo "/usr/local/bin/add-route.sh" | \
        sudo tee /etc/profile.d/add-route.sh >/dev/null
    sudo chmod +x /etc/profile.d/add-route.sh
    
    log_info "Route scripti oluşturuldu ve yapılandırıldı"
}

# Git son sürüm (PPA'dan)
install_latest_git() {
    log_step "Git (latest stable from PPA) kuruluyor..."
    
    # PPA eklerken otomatik update'i devre dışı bırak
    sudo add-apt-repository ppa:git-core/ppa -y -n
    
    # Manuel update yap
    sudo apt update -y
    sudo apt install -y git
    
    log_info "Git $(git --version | awk '{print $3}') kuruldu"
}

# Git Delta kurulumu
install_git_delta() {
    log_step "git-delta (syntax-highlighting pager) kuruluyor..."
    sudo apt install -y git-delta
    log_info "git-delta kuruldu"
}

# Git config dosyası
setup_gitconfig() {
    log_step ".gitconfig yapılandırması indiriliyor..."
    
    curl -fsSL https://raw.githubusercontent.com/alirizagurtas/devtools/main/git/.gitconfig \
        -o "$HOME/.gitconfig"
    
    log_info ".gitconfig başarıyla kuruldu"
}

# Geliştirici araçları kurulumu
install_dev_tools() {
    log_step "Geliştirici araçları kuruluyor..."
    
    sudo apt install -y \
        iputils-ping dnsutils nmap btop ncdu \
        jq yq ripgrep bat fzf gh vim whois mkcert

    sudo tee /etc/profile.d/dev-aliases.sh >/dev/null <<'EOF'
alias cat='batcat --paging=never'
alias top='btop'
alias findtxt='rg'
alias json='jq .'
alias yml='yq .'
alias gs='git status'
alias gc='git commit -m'
alias gp='git push'
alias ga='git add .'
alias ghme='gh repo view --web'
EOF
    sudo chmod +x /etc/profile.d/dev-aliases.sh
    
    log_info "Dev araçları ve aliaslar kuruldu"
}

# Gum (Charmbracelet) kurulumu
install_gum() {
    log_step "Gum (Charmbracelet) kuruluyor..."
    
    # Charm GPG key ve repository ekle
    sudo mkdir -p /etc/apt/keyrings
    curl -fsSL https://repo.charm.sh/apt/gpg.key | \
        sudo gpg --dearmor -o /etc/apt/keyrings/charm.gpg
    
    echo "deb [signed-by=/etc/apt/keyrings/charm.gpg] https://repo.charm.sh/apt/ * *" | \
        sudo tee /etc/apt/sources.list.d/charm.list >/dev/null
    
    sudo apt update -y
    sudo apt install -y gum
    
    # Gum optimizasyonu (TERM=dumb için wrapper)
    sudo tee /etc/profile.d/gum-optimize.sh >/dev/null <<'EOF'
# Gum performance optimization
gum() { TERM=dumb /usr/bin/gum "$@"; }
EOF
    sudo chmod +x /etc/profile.d/gum-optimize.sh
    
    log_info "Gum kuruldu: $(gum --version 2>&1 | head -n1)"
}

# Docker CE kurulumu
install_docker() {
    log_step "Docker CE + Buildx + Compose kuruluyor..."

    # Eski/çakışan paketleri kaldır
    local old_packages=(docker.io docker-doc docker-compose docker-compose-v2 podman-docker containerd runc)
    for pkg in "${old_packages[@]}"; do
        sudo apt remove -y "$pkg" 2>/dev/null || true
    done

    # Modern GPG key yönetimi (best practice: /usr/share/keyrings/)
    sudo install -m 0755 -d /usr/share/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | \
        sudo gpg --dearmor -o /usr/share/keyrings/docker.gpg
    sudo chmod a+r /usr/share/keyrings/docker.gpg

    # Docker repository ekle
    local codename
    codename="$(. /etc/os-release && echo "${UBUNTU_CODENAME:-$VERSION_CODENAME}")"
    
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker.gpg] \
https://download.docker.com/linux/ubuntu ${codename} stable" | \
        sudo tee /etc/apt/sources.list.d/docker.list >/dev/null

    sudo apt update -y
    sudo apt install -y docker-ce docker-ce-cli containerd.io \
        docker-buildx-plugin docker-compose-plugin

    # Kullanıcıyı docker grubuna ekle
    local current_user
    current_user="$(whoami)"
    sudo usermod -aG docker "$current_user" || true
    
    # Docker versiyonunu test et (yeni grup yetkisi için newgrp kullan)
    newgrp docker <<EONG
docker version >/dev/null 2>&1 && echo "  ↳ Docker çalışıyor"
EONG

    # Systemd servisi aktif et
    if [[ -d /run/systemd/system ]]; then
        sudo systemctl enable --now docker
        log_info "Docker systemd servisi etkinleştirildi"
    fi
    
    # Docker helper (dm) yükle
    log_step "Docker helper (dm) komutu yükleniyor..."
    sudo curl -fsSL https://raw.githubusercontent.com/alirizagurtas/devtools/main/scripts/dm \
        -o /usr/local/bin/dm
    sudo chmod +x /usr/local/bin/dm
    log_info "dm komutu eklendi: /usr/local/bin/dm"
}

# UV ve Ansible kurulumu
install_uv_and_ansible() {
    log_step "uv (Python package manager) kuruluyor..."
    curl -LsSf https://astral.sh/uv/install.sh | bash
    export PATH="$HOME/.local/bin:$PATH"

    log_step "Ansible [core ${ANSIBLE_VERSION}] kuruluyor..."
    uv tool install "ansible-core==${ANSIBLE_VERSION}" --with ansible --force

    log_step "Ansible Collections for Kubernetes kuruluyor..."
    ansible-galaxy collection install community.kubernetes

    log_info "UV ve Ansible kurulumu tamamlandı"
}

# PATH güncelleme
update_profile_path() {
    log_step "PATH güncellemesi (~/.profile)..."
    
    if ! grep -q "uv/tools/ansible-core/bin" "$HOME/.profile" 2>/dev/null; then
        cat >> "$HOME/.profile" <<'EOF'

# Add uv-managed Ansible binaries to PATH
if [[ -d "$HOME/.local/share/uv/tools/ansible-core/bin" ]]; then
    PATH="$HOME/.local/share/uv/tools/ansible-core/bin:$PATH"
fi
EOF
        log_info "~/.profile güncellendi: uv-managed Ansible PATH eklendi"
    else
        log_info "PATH zaten ~/.profile içinde mevcut, atlanıyor"
    fi
}

# SSH keys kopyalama
copy_ssh_keys() {
    log_step "SSH keys Windows'tan kopyalanıyor..."
    
    local windows_ssh="/mnt/c/Users/arg2/.ssh"
    local wsl_ssh="$HOME/.ssh"
    
    if [[ ! -d "$windows_ssh" ]]; then
        log_info "⚠️  Windows SSH klasörü bulunamadı, atlanıyor"
        return
    fi
    
    # WSL .ssh klasörünü oluştur
    mkdir -p "$wsl_ssh"
    
    # Tüm SSH dosyalarını kopyala
    cp -r "$windows_ssh"/* "$wsl_ssh/" 2>/dev/null || true
    
    # Doğru izinleri ayarla (SSH için kritik!)
    chmod 700 "$wsl_ssh"
    chmod 600 "$wsl_ssh"/id_* 2>/dev/null || true
    chmod 644 "$wsl_ssh"/*.pub 2>/dev/null || true
    chmod 644 "$wsl_ssh"/config 2>/dev/null || true
    chmod 644 "$wsl_ssh"/known_hosts* 2>/dev/null || true
    
    log_info "SSH keys kopyalandı ve izinler ayarlandı"
    echo "  ↳ $(ls -1 "$wsl_ssh" | wc -l) dosya kopyalandı"
}

# GPG keys kopyalama
copy_gpg_keys() {
    log_step "GPG keys Windows'tan kopyalanıyor..."
    
    local windows_gpg="/mnt/c/Users/arg2/.gnupg"
    local wsl_gpg="$HOME/.gnupg"
    
    if [[ ! -d "$windows_gpg" ]]; then
        log_info "⚠️  Windows GPG klasörü bulunamadı, atlanıyor"
        return
    fi
    
    # WSL .gnupg klasörünü oluştur
    mkdir -p "$wsl_gpg"
    
    # GPG dosyalarını kopyala (tüm klasör yapısıyla)
    cp -r "$windows_gpg"/* "$wsl_gpg/" 2>/dev/null || true
    
    # Doğru izinleri ayarla (GPG için kritik!)
    chmod 700 "$wsl_gpg"
    chmod 700 "$wsl_gpg"/private-keys-v1.d 2>/dev/null || true
    chmod 700 "$wsl_gpg"/openpgp-revocs.d 2>/dev/null || true
    chmod 600 "$wsl_gpg"/pubring.kbx* 2>/dev/null || true
    chmod 600 "$wsl_gpg"/trustdb.gpg 2>/dev/null || true
    chmod 600 "$wsl_gpg"/private-keys-v1.d/* 2>/dev/null || true
    
    log_info "GPG keys kopyalandı ve izinler ayarlandı"
    echo "  ↳ $(find "$wsl_gpg" -type f | wc -l) dosya kopyalandı"
}
print_summary() {
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "✅ KURULUM TAMAMLANDI!"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    ansible --version
    echo ""
    docker --version
    docker compose version
    echo ""
    echo "ℹ️  Docker grup yetkisi için WSL'i yeniden başlatmanız gerekebilir:"
    echo "⚠️  wsl --shutdown"
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
}

# === MAIN EXECUTION ===
main() {
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "🚀 WSL Ubuntu Controller Kurulum Scripti"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    
    configure_wsl_network
    update_system
    setup_persistent_route
    install_latest_git
    install_git_delta
    setup_gitconfig
    install_dev_tools
    install_gum
    install_docker
    install_uv_and_ansible
    update_profile_path
    copy_ssh_keys
    copy_gpg_keys
    print_summary
}

main "$@"
