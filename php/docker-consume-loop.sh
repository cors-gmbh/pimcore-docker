#!/bin/sh
# consume-loop: run `messenger:consume` in a loop inside the container.
#
# Workers are meant to exit regularly (--time-limit, --memory-limit) and be
# restarted. Done by Kubernetes, every exit counts as a container restart and
# short intervals end in CrashLoopBackOff. This loop restarts the worker in
# place instead, while a SIGTERM to the container still reaches the worker so
# it finishes its current message (graceful stop). A non-zero exit of the
# worker (real crash) ends the loop with that code, so Kubernetes still sees
# and restarts genuine failures.
#
# Usage: consume-loop <transport> [<transport> ...] [messenger:consume options]
#   command: ["consume-loop", "pimcore_core", "--time-limit=600", "--memory-limit=250M"]
set -u

pid=""
stopping=0

stop() {
  stopping=1
  [ -n "$pid" ] && kill -TERM "$pid" 2>/dev/null
}
trap stop TERM INT QUIT

while [ "$stopping" -eq 0 ]; do
  php bin/console messenger:consume "$@" &
  pid=$!
  # `wait` returns early when a trapped signal arrives; wait again until the
  # worker has really finished its current message and exited.
  wait "$pid"; rc=$?
  while kill -0 "$pid" 2>/dev/null; do
    wait "$pid"; rc=$?
  done
  pid=""
  if [ "$stopping" -eq 1 ]; then
    exit 0
  fi
  if [ "$rc" -ne 0 ]; then
    echo "consume-loop: messenger:consume exited with $rc, giving up" >&2
    exit "$rc"
  fi
done
