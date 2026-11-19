#!/bin/sh
# Pre-launch and post-session shader pipeline cache hook for notrecall.
# Wraps Recall's native portable-pipeline helper (consolidate, warm, and
# --after-session background archive precompilation) per Steam AppID.
set -e

mode="${1:-}"
cache_root="${2:-}"
game_app="${3:-}"
log="${4:-/dev/null}"

support_dir="$HOME/Library/Application Support/notrecall"
helper_dir="$support_dir/helpers"
portable_pipeline="$helper_dir/portable-pipeline"

[ -n "$cache_root" ] || exit 0
pid_file="$cache_root/precompile.pid"

stop_background_precompile() {
  [ -f "$pid_file" ] || return 0
  old_pid=$(cat "$pid_file" 2>/dev/null || true)
  rm -f "$pid_file"
  case "$old_pid" in ''|*[!0-9]*) return 0 ;; esac
  if kill -0 "$old_pid" 2>/dev/null; then
    echo "=== pipeline: stopping in-progress background precompile (pid $old_pid) ===" >> "$log" 2>&1 || true
    kill -TERM -- "-$old_pid" 2>/dev/null || kill -TERM "$old_pid" 2>/dev/null || true
    waited=0
    while kill -0 "$old_pid" 2>/dev/null && [ "$waited" -lt 20 ]; do
      sleep 0.25 2>/dev/null || sleep 1
      waited=$((waited + 1))
    done
    kill -9 -- "-$old_pid" 2>/dev/null || kill -9 "$old_pid" 2>/dev/null || true
  fi
}

if [ ! -x "$portable_pipeline" ]; then
  echo "=== pipeline: $portable_pipeline not installed; in-game DXMT shader caching still active ===" >> "$log" 2>&1 || true
  exit 0
fi

mkdir -p "$cache_root/cache/pipelines"

case "$mode" in
  pre)
    stop_background_precompile
    echo "=== pipeline: pre-launch consolidate & warm ($cache_root) ===" >> "$log" 2>&1 || true
    if [ -n "$game_app" ] && [ -e "$game_app" ]; then
      "$portable_pipeline" "$cache_root" "$game_app" >> "$log" 2>&1 || true
    else
      "$portable_pipeline" "$cache_root" >> "$log" 2>&1 || true
    fi
    ;;
  post)
    if [ "${NOTRECALL_SKIP_PRECOMPILE:-0}" = "1" ]; then
      echo "=== pipeline: post-session precompilation skipped (NOTRECALL_SKIP_PRECOMPILE=1) ===" >> "$log" 2>&1 || true
      exit 0
    fi
    stop_background_precompile
    echo "=== pipeline: spawning detached post-session shader precompilation ===" >> "$log" 2>&1 || true
    post_log="$cache_root/precompile.log"
    if [ -n "$game_app" ] && [ -e "$game_app" ]; then
      set -- "$portable_pipeline" --after-session "$cache_root" "$game_app"
    else
      set -- "$portable_pipeline" --after-session "$cache_root"
    fi
    # Detach into a new session, reparent to launchd, and close inherited FDs > 2
    # so Steam never stays stuck on "Running" waiting for background precompilation.
    if [ -x /usr/bin/perl ]; then
      /usr/bin/perl -MPOSIX=setsid,close -e '
        my ($log_path, $pid_path, @cmd) = @ARGV;
        my $pid = fork();
        exit 1 if !defined $pid;
        exit 0 if $pid > 0;
        setsid();
        $SIG{HUP} = "IGNORE";
        open STDIN,  "<", "/dev/null";
        open STDOUT, ">", $log_path;
        open STDERR, ">&", \*STDOUT;
        for my $fd (3 .. 255) { POSIX::close($fd); }
        if (open my $pf, ">", "$pid_path.tmp") {
          print $pf "$$\n";
          close $pf;
          rename "$pid_path.tmp", $pid_path;
        }
        exec @cmd;
        exit 127;
      ' "$post_log" "$pid_file" "$@" || true
    else
      (
        trap "" HUP
        "$@" > "$post_log" 2>&1 < /dev/null &
        printf '%s\n' "$!" > "$pid_file.tmp" && mv -f "$pid_file.tmp" "$pid_file"
      )
    fi
    ;;
  *)
    echo "usage: $0 <pre|post> <cache_root> [game_app] [log]" >&2
    exit 1
    ;;
esac
