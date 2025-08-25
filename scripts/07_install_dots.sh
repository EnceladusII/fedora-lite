#!/usr/bin/env bash
set -euo pipefail
# Prereqs: fish + npm sass, then run your dotfiles installer (install.fish)

. "$(dirname "$0")/00_helpers.sh"

: "${TARGET_USER:?TARGET_USER must be set}"
UHOME="$(user_home "$TARGET_USER")"
DOTS_PATH="$UHOME/.local/share/caelestia-fedora"
DOTS_REPO_URL="${DOTS_REPO:-https://github.com/EnceladusII/caelestia-fedora.git}"
DOTS_BRANCH_NAME="${DOTS_BRANCH:-main}"
DOTS_ENTRY="${DOTS_SETUP_SCRIPT:-install.fish}"

# 0) Ensure GOPATH is set:
as_user "grep -qxF '# Personal setups' ~/.bashrc || cat >> ~/.bashrc <<'EOF'

# Personal setups
export GOPATH=\"\$HOME/.go\"
export PATH=\"\$GOPATH/bin:\$PATH\"
EOF"

# 1) Ensure base packages (fish, node/npm, foot)
as_root "dnf -y install fish npm"

# 2) Make fish the default shell if requested
if [[ "${DEFAULT_SHELL:-}" == "fish" ]]; then
  fish_path="$(command -v fish || true)"
  if [[ -n "$fish_path" ]]; then
    echo "[INFO] Setting default shell to fish for $TARGET_USER"
    as_root "chsh -s '$fish_path' '$TARGET_USER' || true"
  fi
fi

# 3) Prepare npm global install in user space (avoid sudo for -g)
as_user "mkdir -p ~/.npm-global ~/.config/fish/conf.d"
as_user "npm config set prefix ~/.npm-global"
# ensure PATH for fish sessions
as_user "bash -lc 'cat > ~/.config/fish/conf.d/npm_path.fish <<\"FISH\"
# added by fedora-lite step 7
if test -d \$HOME/.npm-global/bin
    set -gx PATH \$HOME/.npm-global/bin \$PATH
end
FISH'"

# 4) Install sass globally for the user
echo "[INFO] Installing sass (npm -g) for $TARGET_USER"
as_user "npm install -g sass"

# 5) Clone or update your dotfiles repo
if [[ -d "$DOTS_PATH/.git" ]]; then
  echo "[INFO] Updating existing dots at $DOTS_PATH"
  as_user "git -C '$DOTS_PATH' fetch --all --prune && git -C '$DOTS_PATH' checkout '$DOTS_BRANCH_NAME' && git -C '$DOTS_PATH' pull --ff-only"
else
  echo "[INFO] Cloning dots from $DOTS_REPO_URL to $DOTS_PATH"
  as_user "git clone --branch '$DOTS_BRANCH_NAME' '$DOTS_REPO_URL' '$DOTS_PATH'"
fi

# 6) Run your installer (fish)
if [[ -f "$DOTS_PATH/$DOTS_ENTRY" ]]; then
  echo "[INFO] Running $DOTS_ENTRY via fish"
  as_user "cd '$DOTS_PATH' && fish './$DOTS_ENTRY'"
else
  echo "ERROR: Entry script '$DOTS_ENTRY' not found in $DOTS_PATH" >&2
  exit 1
fi

echo "[OK] Dotfiles installed with fish + npm sass ready."
