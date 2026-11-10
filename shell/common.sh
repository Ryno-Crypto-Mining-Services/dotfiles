case $- in
  *i*) ;;
  *) return 0 ;;
esac

if [ -n "${1:-}" ]; then
  case ":$PATH:" in
    *":$1:"*) ;;
    *) PATH="$1${PATH:+:$PATH}"; export PATH ;;
  esac
fi

alias ll >/dev/null 2>&1 || alias ll='ls -la'
alias gs >/dev/null 2>&1 || alias gs='git status --short --branch'
alias gd >/dev/null 2>&1 || alias gd='git diff'
alias gl >/dev/null 2>&1 || alias gl='git log --oneline --decorate -10'

if ! command -v croot >/dev/null 2>&1; then
  croot() {
    local terrahash_root
    terrahash_root=$(git rev-parse --show-toplevel 2>/dev/null) || {
      printf '%s\n' 'croot: not inside a Git worktree' >&2
      return 1
    }
    cd "$terrahash_root" || return 1
  }
fi

if [ -n "${HOME:-}" ] && [ -r "$HOME/.config/terrahash-dotfiles/local.sh" ]; then
  # shellcheck disable=SC1091
  . "$HOME/.config/terrahash-dotfiles/local.sh"
fi
