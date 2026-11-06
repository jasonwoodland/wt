# shellcheck shell=sh
# Shared by Bash rendering and the generated zsh completion.
# Override auto-detection for terminals/multiplexers that obscure their identity.
wt_hyperlinks_enabled() {
  case "${WT_HYPERLINKS:-auto}" in
    always|1) return 0 ;;
    never|0) return 1 ;;
  esac
  case "${TERM_PROGRAM:-}" in
    iTerm.app|WezTerm|ghostty|vscode|mintty|Hyper|contour) return 0 ;;
  esac
  case "${TERM:-}" in
    xterm-kitty|foot*|contour*|ghostty*) return 0 ;;
  esac
  [ -n "${KITTY_WINDOW_ID:-}${WT_SESSION:-}${VTE_VERSION:-}" ]
}
