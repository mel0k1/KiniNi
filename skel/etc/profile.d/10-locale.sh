# shellcheck shell=sh disable=SC1091
# system locale, written by kiwi-install (or manually in /etc/locale.conf)
if [ -r /etc/locale.conf ]; then
        . /etc/locale.conf
        [ -n "${LANG:-}" ] && export LANG
fi
