#!/bin/sh
set -eu

if [ "$#" -lt 3 ] || [ "$#" -gt 5 ]; then
  echo "usage: github-actions.sh <run-id> <state> <title> [run-url] [progress]" >&2
  exit 64
fi

run_id=$1
state=$2
title=$3
run_url=${4-}
progress=${5-}

case "$state" in
  active|progress|needsAction|succeeded|failed) ;;
  *) echo "invalid state: $state" >&2; exit 64 ;;
esac

operation=update
priority=normal
case "$state" in
  active|progress) operation=show ;;
  needsAction) priority=high ;;
  succeeded) operation=event ;;
  failed) operation=event; priority=critical ;;
esac

set -- swift Tools/islet-pulse.swift "$operation" "github-run-$run_id" "$title" \
  --source github-actions --state "$state" --priority "$priority"

if [ -n "$progress" ]; then
  set -- "$@" --progress "$progress"
fi
if [ -n "$run_url" ]; then
  set -- "$@" --action "Open run" "$run_url"
fi

exec "$@"
