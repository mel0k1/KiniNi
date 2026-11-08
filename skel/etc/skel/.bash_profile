# live-session nicety: the kiwi mascot on interactive logins
# shellcheck shell=sh
case $- in
*i*)    if command -v fastfetch >/dev/null 2>&1; then
                fastfetch
        fi ;;
esac

# live-only: tty1 IS the graphical session (the desktop boots straight
# into Xfce via xinit - no display manager in the live image; LightDM is
# used on installed systems instead). the marker file is written by
# mkiso.sh and removed by kiwi-install, so fresh installed users never
# auto-start X from their shell.
if [ -f /etc/kinini/live-session ] && [ "$(tty 2>/dev/null)" = /dev/tty1 ] \
        && [ -z "${DISPLAY:-}" ] && [ -x /usr/bin/startxfce4 ]; then
        # the tty1 console is not a serial line: capture the session output
        # for debugging (~/.xsession-errors)
        exec startxfce4 > "$HOME/.xsession-errors" 2>&1
fi
