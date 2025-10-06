#!/usr/bin/env bash
set -Eeuo pipefail

# ===== Meta & Defaults =====
readonly SCRIPT_NAME="$(basename "$0")"
readonly VM_NET_CIDR="${VM_NET_CIDR:-10.10.0.0/19}"
readonly ANSIBLE_VERSION="2.19.2"
readonly CURRENT_USER="$(id -un)"
# shellcheck disable=SC1091
. /etc/os-release >/dev/null 2>&1 || true
readonly CODENAME="${UBUNTU_CODENAME:-${VERSION_CODENAME:-noble}}"
readonly ARCH="$(dpkg --print-architecture)"

# Non-interactive apt
export DEBIAN_FRONTEND=noninteractive

# ===== Logging & Traps =====
log() { printf '%s %s\n' "$1" "${*:2}"; }           # usage: log "✅" "message"
step() { printf '\n%s %s\n' "🔧" "$*"; }
err_trap() { log "❌" "Hata! Komut: '${BASH_COMMAND}'  Satır: ${BASH_LINENO[*]}"; exit 1; }
trap err_trap ERR

# ===== Helpers =====
apt_update_once() {
  if [[ ! -f /var/lib/apt/periodic/updated-stamp ]] || find /var/lib/apt/ -name 'lists/*Packages' -mmin +30 >/dev/null 2>&1; then
    sudo apt-get update -y
  fi
}
apt_install() { sudo apt-get install -y --no-install-recommends "$@"; }
write_root_file() { # usage: write_root_file /path/to/file <<'EOF' ... EOF
  sudo tee "$1" >/dev/null
}
ensure_dir() { sudo install -d -m "${3:-0755}" "$2" >/dev/null 2>&1 || sudo mkdir -p "$2"; } # usage ensure_dir owner:group /dir 0755

# ===== System base =====
update_system() {
  step "Sistem güncelleniyor ve temel araçlar kuruluyor…"
  apt_update_once
  sudo apt-get upgrade -y
  apt_install ca-certificates curl gnupg net-tools iproute2 nano
}

# ===== Persistent route (WSL → VM ağları) =====
setup_persistent_route() {
  step "Kalıcı route betiği ayarlanıyor…"
  write_root_file /usr/local/bin/add-route.sh <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
GW="$(grep -m1 '^nameserver ' /etc/resolv.conf | awk '{print $2}')"
[[ -n "$GW" ]] && sudo ip route add __VM_NET_CIDR__ via "$GW" 2>/dev/null || true
EOF
  sudo sed -i "s|__VM_NET_CIDR__|${VM_NET_CIDR}|g" /usr/local/bin/add-route.sh
  sudo chmod +x /usr/local/bin/add-route.sh

  write_root_file /etc/sudoers.d/99-wsl-route <<EOF
${CURRENT_USER} ALL=(ALL) NOPASSWD: /usr/local/bin/add-route.sh, /usr/sbin/ip
EOF
  sudo chmod 0440 /etc/sudoers.d/99-wsl-route

  write_root_file /etc/profile.d/add-route.sh <<'EOF'
#!/usr/bin/env bash
/usr/local/bin/add-route.sh >/dev/null 2>&1 || true
EOF
  sudo chmod +x /etc/profile.d/add-route.sh

  log "✅" "Route scripti oluşturuldu ve etkin."
}

# ===== Git (latest PPA) + delta =====
install_latest_git() {
  step "Git (PPA) kuruluyor…"
  sudo add-apt-repository -y -n ppa:git-core/ppa
  sudo apt-get update -y
  apt_install git
  log "✅" "Git $(git --version | awk '{print $3}')" 
}
install_git_delta() {
  step "git-delta kuruluyor…"
  apt_install git-delta
  log "✅" "git-delta kuruldu."
}

# ===== Git config =====
setup_gitconfig() {
  step ".gitconfig ayarlanıyor…"
  curl -fSLo "$HOME/.gitconfig" \
    https://raw.githubusercontent.com/alirizagurtas/devtools/main/git/.gitconfig
  log "✅" ".gitconfig indirildi."
}

# ===== Dev tools & aliases =====
install_dev_tools() {
  step "Geliştirici araçları kuruluyor…"
  apt_install iputils-ping dnsutils nmap btop ncdu \
             jq yq ripgrep bat fzf gh vim whois mkcert
  write_root_file /etc/profile.d/dev-aliases.sh <<'EOF'
# — Dev aliases —
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
  log "✅" "Dev araçları ve aliaslar hazır."
}

# ===== Gum (Charmbracelet) =====
install_gum() {
  step "Gum kuruluyor…"
  ensure_dir root:root /etc/apt/keyrings
  curl -fsSL https://repo.charm.sh/apt/gpg.key | sudo gpg --dearmor -o /etc/apt/keyrings/charm.gpg
  write_root_file /etc/apt/sources.list.d/charm.list <<'EOF'
deb [signed-by=/etc/apt/keyrings/charm.gpg] https://repo.charm.sh/apt/ * *
EOF
  sudo apt-get update -y
  apt_install gum
  # TERM=dumb wrapper (yavaş terminalde hız için)
  write_root_file /etc/profile.d/gum-optimize.sh <<'EOF'
# Gum performance optimization
gum() { TERM=dumb /usr/bin/gum "$@"; }
EOF
  sudo chmod +x /etc/profile.d/gum-optimize.sh
  log "✅" "Gum: $({ gum --version || true; } 2>&1 | head -n1)"
}

# ===== Docker CE + Compose/Buildx =====
install_docker() {
  step "Docker CE + Buildx + Compose kuruluyor…"
  # Çakışan paketleri kaldır
  local old_pkgs=(docker.io docker-doc docker-compose docker-compose-v2 podman-docker containerd runc)
  for p in "${old_pkgs[@]}"; do sudo apt-get remove -y "$p" 2>/dev/null || true; done

  ensure_dir root:root /usr/share/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /usr/share/keyrings/docker.gpg
  sudo chmod a+r /usr/share/keyrings/docker.gpg

  write_root_file /etc/apt/sources.list.d/docker.list <<EOF
deb [arch=${ARCH} signed-by=/usr/share/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu ${CODENAME} stable
EOF
  sudo apt-get update -y
  apt_install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

  sudo usermod -aG docker "${CURRENT_USER}" || true

  # Docker servis
  if [[ -d /run/systemd/system ]]; then
    sudo systemctl enable --now docker
    log "✅" "Docker systemd servisi etkin."
  fi

  # dm helper
  step "Docker helper (dm) yükleniyor…"
  curl -fSLo /tmp/dm https://raw.githubusercontent.com/alirizagurtas/devtools/main/scripts/dm
  sudo install -m 0755 /tmp/dm /usr/local/bin/dm
  rm -f /tmp/dm
  log "✅" "dm komutu yüklendi (/usr/local/bin/dm)."
}

# ===== UV & Ansible =====
install_uv_and_ansible() {
  step "uv kuruluyor…"
  curl -LsSf https://astral.sh/uv/install.sh | bash
  export PATH="$HOME/.local/bin:$PATH"

  step "Ansible [core ${ANSIBLE_VERSION}] kuruluyor…"
  uv tool install "ansible-core==${ANSIBLE_VERSION}" --with ansible --force

  step "Ansible Collections (community.kubernetes)…"
  ansible-galaxy collection install community.kubernetes
  log "✅" "UV ve Ansible kuruldu."
}

# ===== PATH update for uv/ansible =====
update_profile_path() {
  step "PATH güncelleniyor (~/.profile)…"
  local needle='$HOME/.local/share/uv/tools/ansible-core/bin'
  if ! grep -Fq "$needle" "$HOME/.profile" 2>/dev/null; then
    cat >> "$HOME/.profile" <<'EOF'

# Add uv-managed Ansible binaries to PATH
if [[ -d "$HOME/.local/share/uv/tools/ansible-core/bin" ]]; then
  PATH="$HOME/.local/share/uv/tools/ansible-core/bin:$PATH"
fi
EOF
    log "✅" "~/.profile güncellendi."
  else
    log "ℹ️" "PATH zaten ayarlı, atlanıyor."
  fi
}

# ===== SSH / GPG keys copy (WSL → Linux home) =====
copy_ssh_keys() {
  step "SSH anahtarları kopyalanıyor (Windows → WSL)…"
  local win="/mnt/c/Users/arg2/.ssh" wsl="$HOME/.ssh"
  [[ -d "$win" ]] || { log "⚠️" "Windows SSH klasörü yok, atlanıyor."; return 0; }
  mkdir -p "$wsl"
  cp -r "$win"/* "$wsl/" 2>/dev/null || true
  chmod 700 "$wsl"; chmod 600 "$wsl"/id_* 2>/dev/null || true
  chmod 644 "$wsl"/*.pub "$wsl"/config "$wsl"/known_hosts* 2>/dev/null || true
  log "✅" "SSH anahtarları kopyalandı. ($(ls -1 "$wsl" | wc -l) dosya)"
}
copy_gpg_keys() {
  step "GPG anahtarları kopyalanıyor (Windows → WSL)…"
  local win="/mnt/c/Users/arg2/.gnupg" wsl="$HOME/.gnupg"
  [[ -d "$win" ]] || { log "⚠️" "Windows GPG klasörü yok, atlanıyor."; return 0; }
  mkdir -p "$wsl"
  cp -r "$win"/* "$wsl/" 2>/dev/null || true
  chmod 700 "$wsl" "$wsl"/private-keys-v1.d 2>/dev/null || true
  chmod 700 "$wsl"/openpgp-revocs.d 2>/dev/null || true
  chmod 600 "$wsl"/pubring.kbx* "$wsl"/trustdb.gpg 2>/dev/null || true
  chmod 600 "$wsl"/private-keys-v1.d/* 2>/dev/null || true
  log "✅" "GPG anahtarları kopyalandı. ($(find "$wsl" -type f | wc -l) dosya)"
}

# ===== Summary =====
print_summary() {
  printf '\n%s\n' "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  printf '%s\n' "✅ KURULUM TAMAMLANDI!"
  printf '%s\n\n' "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  { ansible --version || true; } 2>/dev/null
  echo
  { docker --version && docker compose version; } 2>/dev/null || true
  echo
  echo "ℹ️  Docker grup yetkisi için WSL'i yeniden başlatmanız gerekebilir:"
  echo "⚠️  wsl --shutdown"
  echo
}

# ===== Main =====
main() {
  printf '%s\n' "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  printf '%s\n' "🚀 WSL Ubuntu Controller Kurulum Scripti"
  printf '%s\n' "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

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
