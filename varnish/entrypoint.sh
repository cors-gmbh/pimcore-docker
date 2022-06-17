#!/bin/sh
set -e

printenv

envsubst < /etc/varnish/varnish.tmpl > /etc/varnish/varnish.vcl

cat /etc/varnish/varnish.vcl

# this will check if the first argument is a flag
# but only works if all arguments require a hyphenated flag
# -v; -SL; -f arg; etc will work, but not arg1 arg2
if [ "$#" -eq 0 ] || [ "${1#-}" != "$1" ]; then
    set -- varnishd \
	    -F \
	    -f /etc/varnish/varnish.vcl \
	    -a http=:3000,HTTP \
	    "$@"
fi

exec "$@"