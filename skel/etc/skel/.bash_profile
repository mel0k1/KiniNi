# live-session nicety: the kiwi mascot on interactive logins
case $- in
*i*)    if command -v fastfetch >/dev/null 2>&1; then
                fastfetch
        fi ;;
esac
