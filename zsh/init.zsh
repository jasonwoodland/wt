# Source once from .zshrc after adding wt to PATH. No request runs at startup.
autoload -Uz add-zle-hook-widget
# The completion loader installs generated code into the shell. Reload it when
# this setup is sourced again, so an existing shell picks up wt updates too.
unfunction _wt 2>/dev/null || true
autoload -Uz _wt
if (( $+functions[compdef] )); then
  compdef _wt wt
fi
if (( $+functions[_wt_pr_reset] )); then
  _wt_pr_reset
fi
typeset -g _wt_pr_fd='' _wt_pr_cwd='' _wt_pr_started=0

_wt_pr_reset() {
  if [[ -n $_wt_pr_fd ]]; then
    exec {_wt_pr_fd}<&-
  fi
  _wt_pr_fd=''
  _wt_pr_cwd=''
  _wt_pr_started=0
}

_wt_pr_prefetch() {
  # This fast path runs on redraws. Git and gh run only in the child.
  [[ $BUFFER == wt || $BUFFER == 'wt '* ]] || return 0
  [[ $_wt_pr_started == 0 || $_wt_pr_cwd != $PWD ]] || return 0
  _wt_pr_reset
  _wt_pr_started=1
  _wt_pr_cwd=$PWD
  exec {_wt_pr_fd}< <(command wt __pr_refresh >/dev/null 2>&1; print -r -- done)
  return 0
}

_wt_pr_wait() {
  local reply
  if [[ $_wt_pr_started == 0 || $_wt_pr_cwd != $PWD ]]; then
    command wt __pr_refresh >/dev/null 2>&1
    return 0
  fi
  if [[ -n $_wt_pr_fd ]]; then
    read -r -u $_wt_pr_fd reply
    exec {_wt_pr_fd}<&-
    _wt_pr_fd=''
  fi
  return 0
}

add-zle-hook-widget line-init _wt_pr_reset
add-zle-hook-widget line-finish _wt_pr_reset
add-zle-hook-widget line-pre-redraw _wt_pr_prefetch
