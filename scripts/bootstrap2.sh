#!/usr/bin/env bash
# WSL Ubuntu 24.04 Controller Bootstrap — sade & idempotent
set -euo pipefail

# ========= Config =========
readonly VM_NET_CIDR="${VM_NET_CIDR:-10.10.0.0/19}"
readonly ANSIBLE_VERSION="2.19.2"

# ========= Detects =========
CURRENT_USER="$(id -un)"
. /etc/os-release >/dev/null 2>&1 || true
CODENAME="${UBUNTU_CODENAME:-${VERSION_CODENAME:-noble}}"
ARCH="$(dpkg --print-architecture)"
export DEBIAN_FRONTEND=noninteractive

# ========= Logging =========
ok()   { echo "✅ $*"; }
step() { echo; echo "🔧 $*"; }

# ========= APT helpers =========
apt_update()  { sudo apt update -y; }
apt_upgrade() { sudo apt upgrade -y; }
apt_install() { sudo apt install -y --no-install-recommends "$@"; }

# ========= 1) Sistem + Temel & Dev paketler (tek blok) =========
install_base_and_tools() {
  step "Sistem güncelleme ve temel/dev paketler…"
  apt_update
  apt_upgrade

  # — temel & dev paketler (repo gerektirmeyenler) —
  apt_install \
    ca-certificates \
    curl \
    gnupg \
    net-tools \
    iproute2 \
    nano \
    software-properties-common \
    iputils-ping \
    dnsutils \
    nmap \
    btop \
    ncdu \
    jq \
    yq \
    ripgrep \
    bat \
    fzf \
    gh \
    vim \
    whois \
    mkcert \
    git-delta

  # dev aliaslar
  sudo tee /etc/profile.d/dev-aliases.sh >/dev/null <<'EOF'
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

  ok "Temel sistem ve dev araçlar kuruldu."
}

# ========= 2) Kalıcı route (WSL → VM ağı) =========
setup_persistent_route() {
  step "Kalıcı route betiği…"
  sudo tee /usr/local/bin/add-route.sh >/dev/null <<EOF
#!/usr/bin/env bash
set -euo pipefail
GW=\$(grep -m1 '^nameserver ' /etc/resolv.conf | awk '{print \$2}')
[[ -n "\$GW" ]] && sudo ip route add ${VM_NET_CIDR} via "\$GW" 2>/dev/null || true
EOF
  sudo chmod +x /usr/local/bin/add-route.sh

  echo "${CURRENT_USER} ALL=(ALL) NOPASSWD: /usr/local/bin/add-route.sh, /usr/sbin/ip" \
    | sudo tee /etc/sudoers.d/99-wsl-route >/dev/null
  sudo chmod 0440 /etc/sudoers.d/99-wsl-route

  sudo tee /etc/profile.d/add-route.sh >/dev/null <<'EOF'
#!/usr/bin/env bash
/usr/local/bin/add-route.sh >/dev/null 2>&1 || true
EOF
  sudo chmod +x /etc/profile.d/add-route.sh
  ok "Route script etkin."
}

# ========= 3) Git (PPA) =========
install_git_latest() {
  step "Git (PPA) kuruluyor…"
  sudo add-apt-repository -y -n ppa:git-core/ppa
  apt_update
  apt_install \
    git
  ok "Git $(git --version | awk '{print $3}') kuruldu."
}

# ========= 4) Git config =========
setup_gitconfig() {
  step ".gitconfig indiriliyor…"
  curl -fsSL https://raw.githubusercontent.com/alirizagurtas/devtools/main/git/.gitconfig -o "$HOME/.gitconfig"
  ok ".gitconfig kuruldu."
}

# ========= 5) Gum (Charmbracelet) =========
install_gum() {
  step "Gum kuruluyor…"
  sudo install -d -m 0755 /etc/apt/keyrings
  curl -fsSL https://repo.charm.sh/apt/gpg.key | sudo gpg --dearmor -o /etc/apt/keyrings/charm.gpg
  sudo tee /etc/apt/sources.list.d/charm.list >/dev/null <<'EOF'
deb [signed-by=/etc/apt/keyrings/charm.gpg] https://repo.charm.sh/apt/ * *
EOF
  apt_update
  apt_install \
    gum
  # basit wrapper
  sudo tee /etc/profile.d/gum-optimize.sh >/dev/null <<'EOF'
# Gum performance optimization
gum() { TERM=dumb /usr/bin/gum "$@"; }
EOF
  sudo chmod +x /etc/profile.d/gum-optimize.sh
  ok "Gum: $(gum --version 2>&1 | head -n1)"
}

# ========= 6) Docker CE + Buildx + Compose =========
install_docker() {
  step "Docker CE + Buildx + Compose kuruluyor…"
  # Çakışanlar yoksa atlar
  for p in docker.io docker-doc docker-compose docker-compose-v2 podman-docker containerd runc; do
    sudo apt remove -y "$p" 2>/dev/null || true
  done

  sudo install -d -m 0755 /usr/share/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /usr/share/keyrings/docker.gpg
  sudo chmod a+r /usr/share/keyrings/docker.gpg
  sudo tee /etc/apt/sources.list.d/docker.list >/dev/null <<EOF
deb [arch=${ARCH} signed-by=/usr/share/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu ${CODENAME} stable
EOF
  apt_update
  apt_install \
    docker-ce \
    docker-ce-cli \
    containerd.io \
    docker-buildx-plugin \
    docker-compose-plugin

  sudo usermod -aG docker "${CURRENT_USER}" || true
  newgrp docker <<'EONG'
docker version >/dev/null 2>&1 && echo "  ↳ Docker (root'suz) çalışıyor"
EONG
  if [[ -d /run/systemd/system ]]; then
    sudo systemctl enable --now docker
  fi

  # dm helper
  curl -fsSL https://raw.githubusercontent.com/alirizagurtas/devtools/main/scripts/dm -o /tmp/dm
  sudo install -m 0755 /tmp/dm /usr/local/bin/dm
  rm -f /tmp/dm
  ok "Docker & dm hazır."
}

# ========= 7) UV & Ansible =========
install_uv_and_ansible() {
  step "uv kuruluyor…"
  curl -LsSf https://astral.sh/uv/install.sh | bash

  step "Ansible [core ${ANSIBLE_VERSION}] kuruluyor…"
  "$HOME/.local/bin/uv" tool install "ansible-core==${ANSIBLE_VERSION}" --with ansible --force

  # Mutlak yoldan ansible-galaxy (PATH’e bağlı değil)
  local UV_TOOLS_BIN="$HOME/.local/share/uv/tools/ansible-core/bin"
  step "Ansible Collections (community.kubernetes)…"
  "$UV_TOOLS_BIN/ansible-galaxy" collection install community.kubernetes

  ok "UV ve Ansible kuruldu."
}

# ========= 8) PATH kalıcı (login & non-login) =========
update_profile_path() {
  step "PATH kalıcı güncelleniyor (~/.profile & ~/.bashrc)…"

  # ~/.profile
  if ! grep -Fq '$HOME/.local/bin' "$HOME/.profile" 2>/dev/null; then
    cat >> "$HOME/.profile" <<'EOF'

# Local user bin
if [[ -d "$HOME/.local/bin" ]]; then
  PATH="$HOME/.local/bin:$PATH"
fi
EOF
  fi
  if ! grep -Fq '$HOME/.local/share/uv/tools/ansible-core/bin' "$HOME/.profile" 2>/dev/null; then
    cat >> "$HOME/.profile" <<'EOF'
# uv-managed Ansible binaries
if [[ -d "$HOME/.local/share/uv/tools/ansible-core/bin" ]]; then
  PATH="$HOME/.local/share/uv/tools/ansible-core/bin:$PATH"
fi
EOF
  fi

  # ~/.bashrc (non-login)
  if ! grep -Fq '$HOME/.local/bin' "$HOME/.bashrc" 2>/dev/null; then
    cat >> "$HOME/.bashrc" <<'EOF'

# Ensure user-local bin in non-login shells
if [[ -d "$HOME/.local/bin" ]] && [[ ":$PATH:" != *":$HOME/.local/bin:"* ]]; then
  PATH="$HOME/.local/bin:$PATH"
fi
EOF
  fi
  if ! grep -Fq '$HOME/.local/share/uv/tools/ansible-core/bin' "$HOME/.bashrc" 2>/dev/null; then
    cat >> "$HOME/.bashrc" <<'EOF'
# Ensure uv-managed Ansible in non-login shells
if [[ -d "$HOME/.local/share/uv/tools/ansible-core/bin" ]] && [[ ":$PATH:" != *":$HOME/.local/share/uv/tools/ansible-core/bin:"* ]]; then
  PATH="$HOME/.local/share/uv/tools/ansible-core/bin:$PATH"
fi
EOF
  fi

  ok "PATH kalıcı olarak yazıldı."
}

# ========= 9) SSH & GPG (isteğe bağlı kopya) =========
copy_ssh_keys() {
  step "SSH anahtarları (Windows → WSL)…"
  local win="/mnt/c/Users/arg2/.ssh" wsl="$HOME/.ssh"
  [[ -d "$win" ]] || { ok "Windows SSH klasörü yok, atlandı."; return 0; }
  mkdir -p "$wsl"
  cp -r "$win"/* "$wsl/" 2>/dev/null || true
  chmod 700 "$wsl"; chmod 600 "$wsl"/id_* 2>/dev/null || true
  chmod 644 "$wsl"/*.pub "$wsl"/config "$wsl"/known_hosts* 2>/dev/null || true
  ok "SSH anahtarları kopyalandı."
}
copy_gpg_keys() {
  step "GPG anahtarları (Windows → WSL)…"
  local win="/mnt/c/Users/arg2/.gnupg" wsl="$HOME/.gnupg"
  [[ -d "$win" ]] || { ok "Windows GPG klasörü yok, atlandı."; return 0; }
  mkdir -p "$wsl"
  cp -r "$win"/* "$wsl/" 2>/dev/null || true
  chmod 700 "$wsl" "$wsl"/private-keys-v1.d 2>/dev/null || true
  chmod 700 "$wsl"/openpgp-revocs.d 2>/dev/null || true
  chmod 600 "$wsl"/pubring.kbx* "$wsl"/trustdb.gpg "$wsl"/private-keys-v1.d/* 2>/dev/null || true
  ok "GPG anahtarları kopyalandı."
}

# ========= 10) Tailscale =========
install_tailscale() {
  step "Tailscale kuruluyor…"
  sudo install -d -m 0755 /usr/share/keyrings
  curl -fsSL "https://pkgs.tailscale.com/stable/ubuntu/${CODENAME}.noarmor.gpg" \
    | sudo tee /usr/share/keyrings/tailscale-archive-keyring.gpg >/dev/null
  sudo tee /etc/apt/sources.list.d/tailscale.list >/dev/null <<EOF
deb [signed-by=/usr/share/keyrings/tailscale-archive-keyring.gpg] https://pkgs.tailscale.com/stable/ubuntu ${CODENAME} main
EOF
  apt_update
  apt_install \
    tailscale
  if [[ -d /run/systemd/system ]]; then
    sudo systemctl enable --now tailscaled
    ok "tailscaled aktif. İlk bağlantı: sudo tailscale up --accept-routes --ssh"
  else
    ok "WSL systemd kapalıysa: sudo tailscaled --tun=userspace-networking &  # geçici"
  fi
}

# ========= Summary =========
print_summary() {
  echo; echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "✅ KURULUM TAMAMLANDI!"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"; echo
  { git --version; } 2>/dev/null || true
  { ansible --version; } 2>/dev/null || true
  { docker --version && docker compose version; } 2>/dev/null || true
  { tailscale version; } 2>/dev/null || true
  echo
  echo "ℹ️ Docker grubu etkisi için gerekirse: wsl --shutdown"
}

# ========= Main =========
main() {
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "🚀 WSL Ubuntu Controller Kurulum Scripti"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

  install_base_and_tools
  setup_persistent_route
  install_git_latest
  setup_gitconfig
  install_gum
  install_docker
  install_uv_and_ansible
  update_profile_path
  copy_ssh_keys
  copy_gpg_keys
  install_tailscale
  print_summary
}

main "$@"
