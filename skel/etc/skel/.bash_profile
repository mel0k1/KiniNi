# live-session nicety: the kiwi mascot on interactive logins
# shellcheck shell=sh
case $- in
*i*)    if command -v fastfetch >/dev/null 2>&1; then
                fastfetch
        fi ;;
esac
