#!/usr/bin/env bash
#
# Mutual Vision developer workstation bootstrap (macOS + Linux).
#
#   curl -fsSL https://raw.githubusercontent.com/yolkstudio/mv-dev-bootstrap/main/bootstrap.sh | bash
#
# Installs Homebrew + base CLIs and Claude Code, sets up git identity and an SSH
# key, signs in to Azure, then clones the private Mv.Common.Tooling repo from Azure DevOps
# and hands over to its install.sh.
#
# Safe to re-run: every step checks before it acts.
#
# This repo is PUBLIC. Keep it free of secrets and internal hostnames; anything
# MV-specific beyond the tooling repo location belongs in Mv.Common.Tooling.

# Everything lives in main(), called on the last line, so a truncated download
# never executes a partial script.
main() {
  set -euo pipefail

  # --- settings (override via env) ------------------------------------------
  local tooling_repo="${MV_TOOLING_REPO:-https://dev.azure.com/Mutual-Vision/Singularity/_git/Mv.Common.Tooling}"
  # MV repos live here; git uses your MV identity for every repo inside it.
  local projects_dir="${MV_PROJECTS_DIR:-$HOME/repos/mutual-vision}"
  projects_dir="${projects_dir%/}"
  local tooling_dir="${MV_TOOLING_DIR:-$projects_dir/Mv.Common.Tooling}"
  # Earlier versions cloned to ~/repos/Mv.Common.Tooling; keep using an existing clone.
  if [[ -z "${MV_TOOLING_DIR:-}" && ! -d "$tooling_dir/.git" && -d "$HOME/repos/Mv.Common.Tooling/.git" ]]; then
    tooling_dir="$HOME/repos/Mv.Common.Tooling"
  fi
  local tooling_ref="${MV_TOOLING_REF:-main}"
  local tenant_id="${MV_TENANT_ID:-949e9f20-d9fa-4c2f-900a-f242465ba80f}"
  local non_interactive="${NONINTERACTIVE:-0}"
  # Entra ID application id of Azure DevOps (constant, public).
  local ado_resource="499b84ac-1321-427f-aa17-267ca6975798"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --non-interactive) non_interactive=1 ;;
      -h|--help) usage; return 0 ;;
      *) abort "Unknown option: $1 (see --help)" ;;
    esac
    shift
  done

  # When piped from curl, stdin is the script itself: prompts must use the TTY.
  if [[ "$non_interactive" != 1 ]] && ! (exec </dev/tty) 2>/dev/null; then
    warn "No terminal available; running non-interactively."
    non_interactive=1
  fi
  export NONINTERACTIVE="$non_interactive"

  preflight
  step "Base packages";        install_linux_prereqs
  step "Homebrew";             install_homebrew
  step "Core CLIs";            brew_install git azure-cli
  step "Claude Code";          install_claude_code
  step "Azure sign-in";        azure_login
  step "Git identity";         configure_git_identity
  step "SSH key";              configure_ssh_key
  step "Azure DevOps access";  configure_ado_git
  wait_for_ado_access
  step "Mv.Common.Tooling";    clone_tooling

  if [[ -x "$tooling_dir/install.sh" ]]; then
    step "Handing over to Mv.Common.Tooling/install.sh"
    if [[ "$non_interactive" == 1 ]]; then
      exec "$tooling_dir/install.sh"
    else
      exec "$tooling_dir/install.sh" </dev/tty
    fi
  fi

  ok "Bootstrap complete. Mv.Common.Tooling is at $tooling_dir (no install.sh yet)."
  info "Open a new terminal so PATH changes take effect."
}

usage() {
  cat <<'EOF'
Usage: bootstrap.sh [--non-interactive]

  --non-interactive   Never prompt (also: NONINTERACTIVE=1). Steps that need
                      a human (Azure sign-in) must already be done.

Environment overrides:
  MV_TOOLING_REPO   private tooling repo URL
  MV_PROJECTS_DIR   folder for MV repos       (default: ~/repos/mutual-vision)
  MV_TOOLING_DIR    clone location            (default: $MV_PROJECTS_DIR/Mv.Common.Tooling)
  MV_TOOLING_REF    branch to check out       (default: main)
  MV_TENANT_ID      Entra tenant for az login
EOF
}

# --- output -----------------------------------------------------------------

if [[ -t 1 ]]; then
  c_bold=$'\033[1m'; c_blue=$'\033[34m'; c_green=$'\033[32m'
  c_yellow=$'\033[33m'; c_red=$'\033[31m'; c_reset=$'\033[0m'
else
  c_bold=""; c_blue=""; c_green=""; c_yellow=""; c_red=""; c_reset=""
fi

step()  { printf '\n%s==> %s%s\n' "$c_bold$c_blue" "$*" "$c_reset"; }
info()  { printf '    %s\n' "$*"; }
ok()    { printf '%s  ✓ %s%s\n' "$c_green" "$*" "$c_reset"; }
warn()  { printf '%s  ! %s%s\n' "$c_yellow" "$*" "$c_reset" >&2; }
abort() { printf '%s  ✗ %s%s\n' "$c_red" "$*" "$c_reset" >&2; exit 1; }

# ask "question" default(y|n) -> returns 0 for yes. Non-interactive: default.
ask() {
  local prompt="$1" default="$2" reply hint="[y/N]"
  [[ "$default" == y ]] && hint="[Y/n]"
  if [[ "$NONINTERACTIVE" == 1 ]]; then
    [[ "$default" == y ]]; return
  fi
  read -r -p "    $prompt $hint " reply </dev/tty || reply=""
  reply="${reply:-$default}"
  [[ "$reply" =~ ^[Yy] ]]
}

# prompt "question" default -> echoes answer
prompt() {
  local question="$1" default="${2:-}" reply
  if [[ "$NONINTERACTIVE" == 1 ]]; then
    printf '%s' "$default"; return
  fi
  read -r -p "    $question${default:+ [$default]}: " reply </dev/tty || reply=""
  printf '%s' "${reply:-$default}"
}

pause() {
  [[ "$NONINTERACTIVE" == 1 ]] && return 1
  read -r -p "    $1 " _ </dev/tty || true
}

have() { command -v "$1" >/dev/null 2>&1; }

# --- steps ------------------------------------------------------------------

preflight() {
  OS="$(uname -s)"
  case "$OS" in
    Darwin|Linux) ;;
    *) abort "Unsupported OS: $OS (macOS and Linux only)." ;;
  esac
  [[ "$EUID" -ne 0 ]] || abort "Run as your normal user, not root (sudo is used where needed)."
  have curl || abort "curl is required."

  step "Mutual Vision developer bootstrap ($OS $(uname -m))"
  info "This will install Homebrew, CLI tools and Claude Code, set up git/SSH, sign"
  info "you in to Azure and clone Mv.Common.Tooling. You may be asked for your password."

  if [[ "$NONINTERACTIVE" != 1 ]]; then
    # shellcheck disable=SC2024 # the redirect is for sudo's password prompt
    sudo -v </dev/tty || abort "sudo access is required."
    # Keep the sudo timestamp fresh while long installs run.
    ( while kill -0 "$$" 2>/dev/null; do sudo -n true 2>/dev/null; sleep 50; done ) &
    SUDO_KEEPALIVE_PID=$!
    trap 'kill "$SUDO_KEEPALIVE_PID" 2>/dev/null || true' EXIT
  fi
}

install_linux_prereqs() {
  if [[ "$OS" != Linux ]]; then
    ok "Not needed on macOS (Homebrew installs the Xcode Command Line Tools)."
    return
  fi
  if have apt-get; then
    sudo apt-get update -qq
    sudo apt-get install -y -qq build-essential procps curl file git openssh-client
  elif have dnf; then
    sudo dnf -y -q group install development-tools || sudo dnf -y -q groupinstall 'Development Tools'
    sudo dnf -y -q install procps-ng curl file git openssh-clients
  else
    abort "Unsupported Linux distribution (need apt-get or dnf)."
  fi
  ok "Base packages installed."
}

brew_prefix() {
  local p
  for p in /opt/homebrew /usr/local /home/linuxbrew/.linuxbrew "$HOME/.linuxbrew"; do
    [[ -x "$p/bin/brew" ]] && { printf '%s' "$p"; return 0; }
  done
  return 1
}

install_homebrew() {
  local prefix
  if ! prefix="$(brew_prefix)"; then
    info "Installing Homebrew..."
    NONINTERACTIVE=1 /bin/bash -c \
      "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
    prefix="$(brew_prefix)" || abort "Homebrew install did not produce a brew binary."
  fi
  eval "$("$prefix/bin/brew" shellenv)"

  # Persist PATH for future shells.
  local line="eval \"\$($prefix/bin/brew shellenv)\"" rc
  case "$(basename "${SHELL:-bash}")" in
    zsh)  rc="$HOME/.zprofile" ;;
    bash) if [[ "$OS" == Darwin ]]; then rc="$HOME/.bash_profile"; else rc="$HOME/.bashrc"; fi ;;
    *)    rc="$HOME/.profile" ;;
  esac
  if ! grep -qsF "$line" "$rc"; then
    printf '\n%s\n' "$line" >> "$rc"
    info "Added Homebrew to $rc"
  fi
  ok "Homebrew $(brew --version | head -1 | awk '{print $2}') at $prefix"
}

brew_install() {
  local pkg missing=()
  for pkg in "$@"; do
    # Some packages are casks on one OS and formulae on another (azure-cli).
    brew list "$pkg" >/dev/null 2>&1 || missing+=("$pkg")
  done
  if [[ ${#missing[@]} -gt 0 ]]; then
    brew install "${missing[@]}"
  fi
  ok "Installed: $*"
}

# Claude Code comes first so it can help with anything that goes wrong after this
# point. Native installer: self-updating, no Node.js needed, installs the
# launcher to ~/.local/bin.
install_claude_code() {
  local bin="$HOME/.local/bin"
  case ":$PATH:" in *":$bin:"*) ;; *) export PATH="$bin:$PATH" ;; esac

  if ! have claude; then
    info "Installing Claude Code (native installer)..."
    curl -fsSL https://claude.ai/install.sh | bash >/dev/null
    have claude || abort "Claude Code install did not produce a claude binary in $bin."
  fi

  # Persist PATH for future shells (same file as Homebrew's shellenv line).
  # shellcheck disable=SC2016 # written literally so it expands in the user's shell
  local line='export PATH="$HOME/.local/bin:$PATH"' rc
  case "$(basename "${SHELL:-bash}")" in
    zsh)  rc="$HOME/.zprofile" ;;
    bash) if [[ "$OS" == Darwin ]]; then rc="$HOME/.bash_profile"; else rc="$HOME/.bashrc"; fi ;;
    *)    rc="$HOME/.profile" ;;
  esac
  if ! grep -qsF "$line" "$rc"; then
    printf '\n%s\n' "$line" >> "$rc"
    info "Added ~/.local/bin to $rc"
  fi
  ok "Claude Code $(claude --version 2>/dev/null | awk '{print $1}')"
  info "Sign in later by running 'claude' once. Mv.Common.Tooling adds the MV plugin."
}

# Prints "display name<TAB>email" from your Azure DevOps profile: the identity ADO
# links commits to. Needs az login.
ado_profile() {
  az rest --resource "$ado_resource" \
    --url "https://app.vssps.visualstudio.com/_apis/profile/profiles/me?api-version=7.1" \
    --query "[displayName, emailAddress]" -o tsv 2>/dev/null | paste -s - -
}

# Name and email for MV repos come from your Azure DevOps profile (refreshed on every
# run) and go in ~/.gitconfig-mv. Git applies them to every repo under the MV projects
# folder (includeIf gitdir), whatever hosts it. Your global identity stays yours for
# every other repo, so each customer can get its own folder and config the same way.
configure_git_identity() {
  local name="" email="" mvcfg="$HOME/.gitconfig-mv" profile global_name global_email
  global_name="$(git config --global user.name || true)"
  global_email="$(git config --global user.email || true)"

  profile="$(ado_profile || true)"
  if [[ "$profile" == *$'\t'*@* ]]; then
    name="${profile%%$'\t'*}"
    email="${profile#*$'\t'}"
  else
    warn "Could not read your Azure DevOps profile."
    name="$(git config --file "$mvcfg" user.name 2>/dev/null || true)"
    email="$(git config --file "$mvcfg" user.email 2>/dev/null \
             || az account show --query user.name -o tsv 2>/dev/null || true)"
    name="$(prompt "Your full name for commits to MV repos" "${name:-$global_name}")"
    email="$(prompt "Your @mutualvision.co.uk email for commits to MV repos" "$email")"
  fi
  [[ -n "$name" ]] && git config --file "$mvcfg" user.name "$name"
  [[ -n "$email" ]] && git config --file "$mvcfg" user.email "$email"
  git config --file "$mvcfg" pull.ff only
  [[ -z "$global_name" && -n "$name" ]] && git config --global user.name "$name"

  # gitdir/i: macOS file systems are case-insensitive, so ~/Repos/Mutual-Vision matches too.
  mkdir -p "$projects_dir"
  # git expands ~ in include paths itself; keeps the config portable across machines.
  # shellcheck disable=SC2088
  local gitdir="$projects_dir/" mvinc="~/.gitconfig-mv"
  # shellcheck disable=SC2088
  [[ "$gitdir" == "$HOME/"* ]] && gitdir="~/${gitdir#"$HOME/"}"
  git config --global "includeIf.gitdir/i:$gitdir.path" "$mvinc"
  [[ -n "$(git config --global init.defaultBranch || true)" ]] || git config --global init.defaultBranch main

  # Older bootstrap versions set the MV email globally. Offer to put your own back.
  if [[ -n "$email" && "$global_email" == "$email" && "$NONINTERACTIVE" != 1 ]]; then
    local other
    other="$(prompt "Email for non-MV repos (Enter to keep $global_email)" "$global_email")"
    if [[ -n "$other" && "$other" != "$global_email" ]]; then
      git config --global user.email "$other"
      global_email="$other"
    fi
  fi

  ok "git: ${name:-<unset>} <${email:-unset}> for repos in $projects_dir (from $mvcfg)"
  info "Clone MV repos into $projects_dir so commits use this identity."
  [[ -n "$global_email" && "$global_email" != "$email" ]] && info "Other repos keep <$global_email>."
  GIT_EMAIL="$email"
}

# Bootstrap versions before this fix appended this block, which pinned Azure DevOps
# to the new ed25519 key with IdentitiesOnly. Anyone whose registered key was id_rsa
# then got "Permission denied (publickey)" on SSH remotes. Removes that exact,
# unedited block; any other ssh.dev.azure.com entry is left alone. Returns 0 if removed.
remove_legacy_ssh_block() {
  local cfg="$1" tmp
  [[ -f "$cfg" ]] || return 1
  tmp="$(mktemp)"
  if awk '
    function flush() {
      if (n) { if (legacy && n >= 4) removed = 1; else for (i = 1; i <= n; i++) print buf[i] }
      n = 0; inblk = 0
    }
    inblk && /^[ \t]/ {
      buf[++n] = $0
      if ($0 !~ /^  (AddKeysToAgent yes|UseKeychain yes|IdentityFile ~\/\.ssh\/id_ed25519|IdentitiesOnly yes)$/) legacy = 0
      next
    }
    inblk { flush() }
    /^Host ssh\.dev\.azure\.com[ \t]*$/ { inblk = 1; legacy = 1; buf[++n] = $0; next }
    { print }
    END { flush(); exit !removed }
  ' "$cfg" > "$tmp"; then
    cp "$cfg" "$cfg.mv-bootstrap.bak"
    cat "$tmp" > "$cfg"
    rm -f "$tmp"
    return 0
  fi
  rm -f "$tmp"
  return 1
}

configure_ssh_key() {
  local dir="$HOME/.ssh" cfg="$HOME/.ssh/config" key="$HOME/.ssh/id_ed25519"
  local k others=""
  mkdir -p "$dir" && chmod 700 "$dir"

  for k in id_rsa id_ecdsa id_ecdsa_sk id_ed25519_sk; do
    [[ -f "$dir/$k" ]] && others="$others $k"
  done

  if [[ -n "$others" ]] && remove_legacy_ssh_block "$cfg"; then
    ok "Removed the ssh.dev.azure.com entry an older bootstrap added, so your${others} key works again"
    info "(backup: $cfg.mv-bootstrap.bak)"
  fi

  # Keep any SSH setup that already exists: we don't know which key is registered in
  # Azure DevOps, and SSH is optional here (git uses HTTPS with your Azure sign-in).
  if grep -qsiE '^[[:space:]]*Host[[:space:]].*ssh\.dev\.azure\.com' "$cfg"; then
    ok "Keeping your existing ssh.dev.azure.com entry in $cfg"
    return
  fi
  if [[ -n "$others" || -f "$key" ]]; then
    ok "Keeping your existing SSH key(s):${others}$([[ -f "$key" ]] && echo " id_ed25519")"
    return
  fi

  info "Generating an ed25519 key. A passphrase is recommended"
  [[ "$OS" == Darwin ]] && info "(it is stored in the macOS keychain, so you only type it once)."
  if [[ "$NONINTERACTIVE" == 1 ]]; then
    ssh-keygen -q -t ed25519 -C "${GIT_EMAIL:-$USER@$(hostname)}" -f "$key" -N ""
  else
    ssh-keygen -t ed25519 -C "${GIT_EMAIL:-$USER@$(hostname)}" -f "$key" </dev/tty
  fi
  ok "Created $key"

  # Load the key into the agent on first use (and on macOS remember the passphrase).
  # No IdentityFile/IdentitiesOnly pinning, so keys added later still get offered.
  {
    printf '\n# Added by mv-dev-bootstrap\nHost ssh.dev.azure.com\n'
    printf '  AddKeysToAgent yes\n'
    [[ "$OS" == Darwin ]] && printf '  UseKeychain yes\n'
  } >> "$cfg"
  chmod 600 "$cfg"
  if [[ "$OS" == Darwin && "$NONINTERACTIVE" != 1 ]]; then
    ssh-add --apple-use-keychain "$key" </dev/tty 2>/dev/null || true
  fi

  info "Optional, only if you want to use SSH remotes: add this key at"
  info "https://dev.azure.com/Mutual-Vision/_usersSettings/keys"
  printf '\n%s\n\n' "$(cat "$key.pub")"
}

azure_login() {
  if az account show >/dev/null 2>&1 \
     && [[ "$(az account show --query tenantId -o tsv)" == "$tenant_id" ]]; then
    ok "Signed in to Azure as $(az account show --query user.name -o tsv)"
    return
  fi
  [[ "$NONINTERACTIVE" == 1 ]] && abort "Not signed in to Azure. Run 'az login --tenant $tenant_id' and re-run."

  info "Sign in with your @mutualvision.co.uk account."
  local args=(login --tenant "$tenant_id" --allow-no-subscriptions)
  if [[ "$OS" == Linux && -z "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ]]; then
    args+=(--use-device-code)
  fi
  az "${args[@]}" </dev/tty >/dev/null
  ok "Signed in to Azure as $(az account show --query user.name -o tsv)"
}

# Git authenticates to Azure DevOps with a short-lived Entra token from the az
# CLI: no PAT, no SSH key upload, and it honours MFA/conditional access.
configure_ado_git() {
  local section="credential.https://dev.azure.com"
  local helper="!f() { test \"\$1\" = get || exit 0; echo username=azure; echo \"password=\$(az account get-access-token --resource $ado_resource --query accessToken -o tsv)\"; }; f"

  if git config --global --get-all "$section.helper" >/dev/null 2>&1 \
     && ! git config --global --get-all "$section.helper" | grep -q "get-access-token"; then
    ok "Keeping your existing Azure DevOps credential helper."
    return
  fi
  git config --global --unset-all "$section.helper" 2>/dev/null || true
  # Empty entry first: ignore generic helpers (e.g. a stale keychain entry).
  git config --global --add "$section.helper" ""
  git config --global --add "$section.helper" "$helper"
  ok "git uses your Azure sign-in for dev.azure.com"
}

wait_for_ado_access() {
  while ! GIT_TERMINAL_PROMPT=0 git ls-remote "$tooling_repo" >/dev/null 2>&1; do
    warn "Can't read $tooling_repo yet."
    info "Ask your team lead for Read access to Mv.Common.Tooling in the"
    info "Singularity project on Azure DevOps (signed in as $(az account show --query user.name -o tsv 2>/dev/null))."
    [[ "$NONINTERACTIVE" == 1 ]] && abort "No access to the tooling repo. Re-run once granted."
    pause "Press Enter to retry once access is granted, or Ctrl-C to stop and re-run later..."
  done
  ok "Access to Mv.Common.Tooling confirmed."
}

clone_tooling() {
  if [[ -d "$tooling_dir/.git" ]]; then
    git -C "$tooling_dir" fetch --quiet origin
    if [[ -n "$(git -C "$tooling_dir" rev-parse --verify --quiet "origin/$tooling_ref" || true)" ]]; then
      git -C "$tooling_dir" checkout --quiet "$tooling_ref"
      git -C "$tooling_dir" pull --quiet --ff-only || warn "Could not fast-forward $tooling_dir; leaving it as is."
    fi
    ok "Updated $tooling_dir"
  else
    mkdir -p "$(dirname "$tooling_dir")"
    git clone --quiet "$tooling_repo" "$tooling_dir"
    if git -C "$tooling_dir" rev-parse --verify --quiet "origin/$tooling_ref" >/dev/null; then
      git -C "$tooling_dir" checkout --quiet "$tooling_ref"
    fi
    ok "Cloned to $tooling_dir"
  fi
}

main "$@"
