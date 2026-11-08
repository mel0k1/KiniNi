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
        && [ -z "${DISPLAY:-}" ] && [ -x /usr/bin/startxfce4 ] \
        && [ -x /usr/bin/Xorg ]; then
        # the tty1 console is not a serial line: capture the session output
        # for debugging (~/.xsession-errors)
        #
        # X is started directly instead of through xinit: xinit waits for
        # a SIGUSR1 "server is ready" signal that Xorg only sends when it
        # inherited SIGUSR1=SIG_IGN from its parent - with this shell's
        # signal layout it never fires and xinit suspends forever (seen in
        # CI: xinit sits in sigsuspend while Xorg is fully initialized).
        # Xorg is setuid on Void, so it runs fine from the session user.
        /usr/bin/Xorg :0 -nolisten tcp vt1 \
                > /dev/null 2>&1 &
        n=0
        while [ ! -S /tmp/.X11-unix/X0 ] && [ "$n" -lt 150 ]; do
                sleep 0.2
                n=$(( n + 1 ))
        done
        DISPLAY=:0 exec dbus-launch --exit-with-session startxfce4 \
                > "$HOME/.xsession-errors" 2>&1
fi
