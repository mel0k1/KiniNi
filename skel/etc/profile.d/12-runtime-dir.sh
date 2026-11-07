# shellcheck shell=sh disable=SC1091
# XDG_RUNTIME_DIR for sessions without systemd/elogind (getty logins,
# console labwc). LightDM sessions get it from kinini-session instead;
# root does not need it.
if [ "$(id -u)" -gt 0 ] && [ -z "${XDG_RUNTIME_DIR:-}" ]; then
        XDG_RUNTIME_DIR="/run/user/$(id -u)"
        export XDG_RUNTIME_DIR
        mkdir -p "$XDG_RUNTIME_DIR" 2>/dev/null
        chmod 700 "$XDG_RUNTIME_DIR" 2>/dev/null
fi
