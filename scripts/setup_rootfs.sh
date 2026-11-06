#!/usr/bin/env bash
# ============================================================
# kenzo (Redmi Note 3 Pro) -- setup_rootfs.sh
#
# Runs INSIDE the arm64 chroot during build-rootfs.sh.
# Installs all packages, tooling, and global configs at build-time so we
# do not depend on the phone having internet/Wi-Fi on first boot.
#
# Usage (from build-rootfs.sh):
#   chroot "$R" /setup_rootfs.sh "$KENZO_USER"
# ============================================================

set -euo pipefail
trap 'echo "[setup_rootfs] setup_rootfs.sh FAILED at line $LINENO: $BASH_COMMAND" >&2' ERR

if [ "$#" -ne 1 ]; then
    echo "usage: $0 <default-user>" >&2
    exit 1
fi
TARGET_USER="$1"
if ! id -u "$TARGET_USER" >/dev/null 2>&1; then
    echo "ERROR: user '$TARGET_USER' does not exist in this rootfs." >&2
    exit 1
fi

if [ -f /etc/kenzo.env ]; then
    _skip_docker="$(grep -E '^SKIP_DOCKER=' /etc/kenzo.env | cut -d= -f2- | tr -d '\"'\'' ' || true)"
    [ -n "$_skip_docker" ] && SKIP_DOCKER="$_skip_docker"
fi
SKIP_DOCKER="${SKIP_DOCKER:-false}"

. /etc/os-release 2>/dev/null || true
CODENAME="${VERSION_CODENAME:-resolute}"
ARCH="$(dpkg --print-architecture)"
case "$ARCH" in
    arm64)  DEB_ARCH="arm64";   FASTFETCH_ARCH="aarch64" ;;
    armhf)  DEB_ARCH="armhf";   FASTFETCH_ARCH="armhf"   ;;
    amd64)  DEB_ARCH="amd64";   FASTFETCH_ARCH="amd64"   ;;
    *)      DEB_ARCH="$ARCH";      FASTFETCH_ARCH="$ARCH"   ;;
esac
echo "[setup_rootfs] arch=$ARCH deb_arch=$DEB_ARCH codename=$CODENAME user=$TARGET_USER"

APT_OPTS=(-o Acquire::Check-Valid-Until=false)
apt_install()          { DEBIAN_FRONTEND=noninteractive apt-get install -y "${APT_OPTS[@]}" "$@"; }
apt_update()           { apt-get update "${APT_OPTS[@]}"; }
apt_install_best_effort() {
    apt_install "$@" && return 0
    echo "[setup_rootfs] bulk install failed -- retrying one by one..."
    local p; for p in "$@"; do apt_install "$p" || echo "[setup_rootfs] WARNING: could not install '$p'" >&2; done
}

export DEBIAN_FRONTEND=noninteractive

apt_update
apt_install curl ca-certificates gnupg lsb-release

# ---- core packages (everything that setup_kenzo.sh used to install on device) ----
apt_install_best_effort \
    zsh git curl wget unzip zip tar tmux htop btop \
    fzf ripgrep fd-find bat ncdu jq tree \
    build-essential python3 python3-pip python3-venv \
    less bash-completion locales tzdata procps psmisc lsof rsync file \
    usbutils iproute2 iputils-ping dnsutils

# ---- eza ----
if ! command -v eza >/dev/null 2>&1; then
    echo "[setup_rootfs] installing eza..."
    if ! apt_install eza; then
        mkdir -p /etc/apt/keyrings
        wget -qO- https://raw.githubusercontent.com/eza-community/eza/main/deb.asc \
            | gpg --dearmor --yes -o /etc/apt/keyrings/gierens.gpg
        echo "deb [signed-by=/etc/apt/keyrings/gierens.gpg] http://deb.gierens.de stable main" \
            | tee /etc/apt/sources.list.d/gierens.list
        chmod 644 /etc/apt/keyrings/gierens.gpg
        apt_update
        apt_install eza || echo "[setup_rootfs] WARNING: eza not installed." >&2
    fi
fi

# ---- zoxide ----
if ! command -v zoxide >/dev/null 2>&1; then
    echo "[setup_rootfs] installing zoxide..."
    apt_install zoxide || curl -sSfL https://raw.githubusercontent.com/ajeetdsouza/zoxide/main/install.sh \
        | bash 2>/dev/null || true
fi

# ---- fastfetch ----
if ! command -v fastfetch >/dev/null 2>&1; then
    echo "[setup_rootfs] installing fastfetch..."
    if ! apt_install fastfetch; then
        wget -qO /tmp/fastfetch.deb \
            "https://github.com/fastfetch-cli/fastfetch/releases/latest/download/fastfetch-linux-${FASTFETCH_ARCH}.deb" \
            && dpkg -i /tmp/fastfetch.deb || echo "[setup_rootfs] WARNING: fastfetch not installed." >&2
        rm -f /tmp/fastfetch.deb
    fi
fi

# ---- delta (git-delta) ----
if ! command -v delta >/dev/null 2>&1; then
    echo "[setup_rootfs] installing delta..."
    if ! apt_install git-delta; then
        DELTA_VERSION="$(curl -fsSL https://api.github.com/repos/dandavison/delta/releases/latest \
            | grep '"tag_name"' | cut -d'"' -f4 || true)"
        if [ -n "$DELTA_VERSION" ]; then
            curl -fsSL "https://github.com/dandavison/delta/releases/download/${DELTA_VERSION}/git-delta_${DELTA_VERSION}_${DEB_ARCH}.deb" \
                -o /tmp/delta.deb && dpkg -i /tmp/delta.deb || echo "[setup_rootfs] WARNING: delta not installed." >&2
            rm -f /tmp/delta.deb
        fi
    fi
fi

# ---- uv ----
if ! command -v uv >/dev/null 2>&1; then
    echo "[setup_rootfs] installing uv..."
    curl -LsSf https://astral.sh/uv/install.sh | UV_UNMANAGED_INSTALL=/usr/local/bin sh 2>/dev/null || echo "[setup_rootfs] WARNING: uv not installed." >&2
fi

# ---- Node 22 ----
if ! command -v node >/dev/null 2>&1; then
    echo "[setup_rootfs] installing Node.js 22..."
    if curl -fsSL https://deb.nodesource.com/setup_22.x | bash - && apt_install nodejs; then
        :
    else
        echo "[setup_rootfs] NodeSource failed -- falling back to Ubuntu nodejs/npm."
        apt_install nodejs npm || echo "[setup_rootfs] WARNING: Node.js not installed." >&2
    fi
fi

# ---- bun ----
if ! command -v bun >/dev/null 2>&1; then
    echo "[setup_rootfs] installing bun..."
    curl -fsSL https://bun.sh/install | BUN_INSTALL=/usr/local bash 2>/dev/null || echo "[setup_rootfs] WARNING: bun not installed." >&2
fi

# ---- GitHub CLI (gh) ----
if ! command -v gh >/dev/null 2>&1; then
    echo "[setup_rootfs] installing GitHub CLI (gh)..."
    {
        install -m 0755 -d /etc/apt/keyrings &&
        curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
            | tee /etc/apt/keyrings/githubcli-archive-keyring.gpg &&
        chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg &&
        echo "deb [arch=${DEB_ARCH} signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
            | tee /etc/apt/sources.list.d/github-cli.list &&
        apt_update &&
        apt_install gh
    } || echo "[setup_rootfs] WARNING: gh not installed." >&2
fi

if [ "$SKIP_DOCKER" != "true" ] && [ "$SKIP_DOCKER" != "1" ]; then
    # ---- Docker compose/buildx plugins (docker.io base pkgs are installed by build-rootfs.sh already) ----
    if command -v docker >/dev/null 2>&1 && ! docker compose version >/dev/null 2>&1; then
        echo "[setup_rootfs] installing docker compose v2 + buildx..."
        apt_install docker-compose-v2 docker-buildx || true
    fi
    if ! docker compose version >/dev/null 2>&1; then
        if curl -fsI "https://download.docker.com/linux/ubuntu/dists/${CODENAME}/Release" >/dev/null 2>&1; then
            install -m 0755 -d /etc/apt/keyrings
            curl -fsSL https://download.docker.com/linux/ubuntu/gpg | tee /etc/apt/keyrings/docker.asc
            chmod a+r /etc/apt/keyrings/docker.asc
            echo "deb [arch=${DEB_ARCH} signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu ${CODENAME} stable" \
                | tee /etc/apt/sources.list.d/docker.list
            apt_update
            apt_install docker-compose-plugin docker-buildx-plugin || true
        fi
    fi

    # ---- Docker daemon.json (log limits) ----
    if [ ! -f /etc/docker/daemon.json ]; then
        mkdir -p /etc/docker
        cat << 'EOF' | tee /etc/docker/daemon.json >/dev/null
{
  "log-driver": "json-file",
  "log-opts": { "max-size": "10m", "max-file": "3" }
}
EOF
    fi

    # ---- Docker: enable units (build-rootfs.sh also enables them; keep in sync) ----
    systemctl enable containerd docker 2>/dev/null || true

    # ---- sysctl.d/networking ----
    mkdir -p /etc/sysctl.d
    [ -f /etc/sysctl.d/99-docker.conf ] || {
        printf 'net.ipv4.ip_forward = 1\nnet.ipv6.conf.all.forwarding = 1\nnet.ipv6.conf.default.forwarding = 1\n' \
            | tee /etc/sysctl.d/99-docker.conf >/dev/null
    }
else
    echo "[setup_rootfs] SKIP_DOCKER=true: skipping docker compose, plugins, daemon config, and services"
    systemctl disable containerd docker 2>/dev/null || true
fi

# ---- iptables nft variant ----
command -v update-alternatives >/dev/null 2>&1 && {
    update-alternatives --set iptables /usr/sbin/iptables-nft 2>/dev/null || true
    update-alternatives --set ip6tables /usr/sbin/ip6tables-nft 2>/dev/null || true
}

# ---- ufw + fail2ban: install + write default jail configs ----
apt_install ufw fail2ban python3-systemd || true

# ============================================================
# User template homedir contents (/etc/skel-ish but per-user)
# ============================================================
# The default user ALREADY exists at this point (build-rootfs.sh creates it).
# We populate the user's dotfiles NOW (Oh My Zsh + plugins, .zshrc, .tmux.conf,
# /usr/local/bin helpers) using the TARGET_USER's $HOME.
# If they already exist, skip (keeps build idempotent-ish on rebuilds).
# ============================================================

USER_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6)"
[ -n "$USER_HOME" ] || { echo "[setup_rootfs] cannot resolve home for $TARGET_USER" >&2; exit 1; }
echo "[setup_rootfs] populating $USER_HOME"

run_as_user() {
    # args: command [args...]
    runuser -u "$TARGET_USER" -- env HOME="$USER_HOME" bash -c 'cd "$HOME" && "$@"' _ "$@"
}

# fd / bat: Ubuntu ships them as fdfind / batcat; link into /usr/local/bin globally
[ -x /usr/bin/fdfind ] && ln -sf /usr/bin/fdfind /usr/local/bin/fd 2>/dev/null || true
[ -x /usr/bin/batcat ] && ln -sf /usr/bin/batcat /usr/local/bin/bat 2>/dev/null || true
# also install user-local copies too so $HOME/.local/bin links still present
run_as_user mkdir -p "$USER_HOME/.local/bin"
[ -x /usr/bin/fdfind ] && run_as_user ln -sf /usr/bin/fdfind "$USER_HOME/.local/bin/fd" 2>/dev/null || true
[ -x /usr/bin/batcat ] && run_as_user ln -sf /usr/bin/batcat "$USER_HOME/.local/bin/bat" 2>/dev/null || true

# ---- helper scripts in ~/bin ----
run_as_user mkdir -p "$USER_HOME/bin"

install_helper() {
    local name="$1"; shift
    local dst="$USER_HOME/bin/$name"
    [ -f "$dst" ] && return 0
    cat > "$dst" << 'HELPEREOF'
$@
HELPEREOF
    chmod 755 "$dst"
    chown "$TARGET_USER:$TARGET_USER" "$dst"
}

if [ "$SKIP_DOCKER" != "true" ] && [ "$SKIP_DOCKER" != "1" ]; then
install_helper ddeploy << 'EOF'
#!/usr/bin/env bash
set -e
cd ~/docker || exit 0
echo "[+] Pulling latest..."
git pull
echo "[+] Updating submodules..."
git submodule sync --recursive
git submodule update --init --recursive
echo "[+] Rebuilding containers..."
docker compose build
echo "[+] Restarting stack..."
docker compose up -d
echo "[+] Done."
EOF

install_helper dockerstart << 'EOF'
#!/usr/bin/env bash
set -e
if docker info >/dev/null 2>&1; then
    echo "dockerd already running."
    exit 0
fi
sudo systemctl restart docker
sleep 2
if docker info >/dev/null 2>&1; then
    echo "dockerd is running."
else
    echo "Failed to start. Check: sudo systemctl status docker / sudo journalctl -u docker -n 100"
    exit 1
fi
EOF
fi

# ---- Oh My Zsh + plugins
if [ ! -d "$USER_HOME/.oh-my-zsh" ]; then
    echo "[setup_rootfs] installing Oh My Zsh for $TARGET_USER..."
    run_as_user bash -c 'sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)" "" --unattended' </dev/null || true
fi

ZSH_CUSTOM="$USER_HOME/.oh-my-zsh/custom"
mkdir -p "$ZSH_CUSTOM/plugins"
chown -R "$TARGET_USER:$TARGET_USER" "$USER_HOME/.oh-my-zsh" 2>/dev/null || true

clone_if_missing() {
    local url="$1" dst="$2"
    [ -d "$dst" ] && return 0
    run_as_user git clone --depth 1 "$url" "$dst" 2>/dev/null || true
}
clone_if_missing https://github.com/zsh-users/zsh-autosuggestions     "$ZSH_CUSTOM/plugins/zsh-autosuggestions"
clone_if_missing https://github.com/zsh-users/zsh-syntax-highlighting "$ZSH_CUSTOM/plugins/zsh-syntax-highlighting"
clone_if_missing https://github.com/zsh-users/zsh-completions         "$ZSH_CUSTOM/plugins/zsh-completions"

# ---- .zshrc (only overwrite if it is still the stock OMZ one or missing) ----
ZSHRC="$USER_HOME/.zshrc"
if [ ! -f "$ZSHRC" ] || ! grep -q '^# KENZO-ZSHRC-MARKER$' "$ZSHRC" 2>/dev/null; then
    echo "[setup_rootfs] writing $ZSHRC"
    cat > "$ZSHRC" << 'ZSHRC_EOF'
# KENZO-ZSHRC-MARKER
export ZSH="$HOME/.oh-my-zsh"

ZSH_THEME="robbyrussell"

plugins=(
    git docker python node npm fzf
    zsh-completions
    zsh-autosuggestions
    zsh-syntax-highlighting
)

[[ -r "$ZSH/oh-my-zsh.sh" ]] && source "$ZSH/oh-my-zsh.sh"

# Fix prompt on Linux console (fbcon/tty1) where UTF-8 arrow glyph doesn't exist
if [[ "$TERM" == "linux" ]]; then
    PROMPT='%(?:%{$fg_bold[green]%}-> :%{$fg_bold[red]%}-> ) %{$fg[cyan]%}%n@%m:%c%{$reset_color%}$(git_prompt_info) '
fi

export PATH="$HOME/.local/bin:$HOME/bin:$PATH"

alias ls='eza --icons --group-directories-first'
alias ll='eza -la --icons --git --group-directories-first'
alias la='eza -la --icons --git'
alias lt='eza --tree --icons --level=2'
alias tree='eza --tree --icons'

alias cat='bat --paging=never'
alias less='bat --paging=always'

alias find='fd'
alias grep='rg'
alias top='btop'
alias du='ncdu --color dark'
alias df='df -h'

setopt SHARE_HISTORY
setopt HIST_IGNORE_ALL_DUPS
setopt HIST_REDUCE_BLANKS
setopt INC_APPEND_HISTORY

HISTSIZE=50000
SAVEHIST=50000

alias gs='git status -sb'
alias ga='git add'
alias gaa='git add -A'
alias gc='git commit -m'
alias gca='git commit --amend --no-edit'
alias gpl='git pull'
alias gps='git push'
alias gpf='git push --force-with-lease'
alias gl='git pull --rebase'
alias gd='git diff'
alias gds='git diff --staged'
alias gb='git branch -vv'
alias gco='git checkout'
alias gsw='git switch'
alias glog='git log --oneline --graph --decorate --all'
alias gloga='git log --graph --oneline --decorate --all --color'
alias gst='git stash'
alias gstp='git stash pop'

alias gsub='git submodule sync --recursive && git submodule update --init --recursive'
alias gsubr='git submodule sync --recursive && git submodule update --init --recursive --remote'

alias dc='docker compose'
alias dcu='docker compose up -d'
alias dcub='docker compose up -d --build'
alias dcd='docker compose down'
alias dcr='docker compose restart'
alias dcl='docker compose logs -f'
alias dclf='docker compose logs -f --tail=100'

alias dps='docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"'
alias dpsa='docker ps -a --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"'

alias di='docker images --format "table {{.Repository}}\t{{.Tag}}\t{{.Size}}"'

alias dprune='docker system prune -f'
alias dclean='docker system prune -af --volumes'
alias dsize='docker system df'

alias py='python3'
alias pip='pip3'
alias venv='python3 -m venv'
alias activate='source venv/bin/activate'

alias ddir='cd ~/docker'

alias t='tmux'
alias ta='tmux attach -t'
alias tls='tmux ls'

export FZF_DEFAULT_COMMAND='fd --type f --hidden --follow --exclude .git --exclude node_modules --exclude .venv --exclude __pycache__'
export FZF_CTRL_T_COMMAND="$FZF_DEFAULT_COMMAND"
export FZF_ALT_C_COMMAND='fd --type d --hidden --follow --exclude .git --exclude node_modules --exclude .venv'

export FZF_DEFAULT_OPTS='
--height=40%
--layout=reverse
--border
--preview "bat --color=always {} 2>/dev/null || cat {}"
'

export FZF_CTRL_R_OPTS="
--preview 'echo {}'
--preview-window=up:3:hidden:wrap
"

eval "$(zoxide init zsh --cmd cd)"

if command -v fastfetch >/dev/null 2>&1; then
    if [[ $- == *i* ]] && [[ "$TTY" != *tty1* ]]; then
        fastfetch
    fi
fi
ZSHRC_EOF
    chown "$TARGET_USER:$TARGET_USER" "$ZSHRC"
fi

# ---- .tmux.conf
TMUXCONF="$USER_HOME/.tmux.conf"
if [ ! -f "$TMUXCONF" ]; then
    cat > "$TMUXCONF" << 'EOF'
set -g mouse on
set -g history-limit 50000
set -g status-bg black
set -g status-fg white
EOF
    chown "$TARGET_USER:$TARGET_USER" "$TMUXCONF"
fi

# ---- /etc/skel copy so any future users get it too
SKEL_ZSHRC=/etc/skel/.zshrc
[ ! -f "$SKEL_ZSHRC" ] && cp "$ZSHRC" "$SKEL_ZSHRC" 2>/dev/null || true
SKEL_TMUX=/etc/skel/.tmux.conf
[ ! -f "$SKEL_TMUX" ] && cp "$TMUXCONF" "$SKEL_TMUX" 2>/dev/null || true

# ---- remove the built-in device setup script copy in the user's home for interactive run later
# (build-rootfs.sh also drops one; we make sure it is executable if dropped from our end too)
[ -f "$USER_HOME/setup_kenzo.sh" ] && chmod 755 "$USER_HOME/setup_kenzo.sh" 2>/dev/null || true
[ -f "$USER_HOME/setup_kenzo.sh" ] && chown "$TARGET_USER:$TARGET_USER" "$USER_HOME/setup_kenzo.sh" 2>/dev/null || true
[ -f /usr/local/sbin/setup_kenzo.sh ] && chmod 755 /usr/local/sbin/setup_kenzo.sh 2>/dev/null || true

# ---- zsh login shells (ssh) never read /etc/profile(.d): hook only the kenzo ssh banner ----
ZPROFILE=/etc/zsh/zprofile
mkdir -p /etc/zsh
if ! grep -q 'KENZO-SSH-BANNER' "$ZPROFILE" 2>/dev/null; then
    cat >> "$ZPROFILE" << 'ZPROFILE_EOF'

# KENZO-SSH-BANNER
[ -r /etc/profile.d/99-kenzo-ssh.sh ] && . /etc/profile.d/99-kenzo-ssh.sh
ZPROFILE_EOF
fi

# ---- set default login shell to zsh
if command -v zsh >/dev/null 2>&1; then
    ZSH_BIN="$(command -v zsh)"
    chsh -s "$ZSH_BIN" "$TARGET_USER" 2>/dev/null || usermod -s "$ZSH_BIN" "$TARGET_USER" 2>/dev/null || true
fi

echo "[setup_rootfs] done."

