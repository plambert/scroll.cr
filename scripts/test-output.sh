#!/usr/bin/env bash

lines=()
random=()
chars='abcdefghijklmnopqrstuvwxyz'
method=trickle
delay=0.25
count=10000

setup() {
  local c i line

  for c in {a..z}; do
    line=""
    for ((i = 0; i < 500; i++)); do line="${line}${c}"; done
    lines+=("$line")
  done

  mapfile -t random < <(seq "$count" | sort -R)
}

method_trickle() {
  local i c l j

  for ((i = 0; i < count; i++)); do
    c="${chars:0:1}"
    chars="${chars:1}${chars:0:1}"
    l=$((100 + (RANDOM % 200)))
    if [[ -n "$random" ]]; then
      idx="${random[0]}"
      random=("${random[@]:1}")
    else
      idx="$((i + 1))"
    fi
    printf '%6d ' "$idx"
    for ((j = 0; j < l; j++)); do
      printf %s "$c"
    done
    printf '\n'
    sleep "$delay"
  done
}

method_line() {
  local line c

  for ((i = 0; i < count; i++)); do
    l=$((100 + (RANDOM % 200)))
    line="${lines[0]:0:$l}"
    if [[ -n "$random" ]]; then
      idx="${random[0]}"
      random=("${random[@]:1}")
    else
      idx="$i"
    fi
    printf '%6d %s\n' "$((idx + 1))" "$line"
    lines=("${lines[@]:1}" "${lines[0]}")
    sleep "$delay"
  done
}

while [[ $# -gt 0 ]]; do
  opt="$1"
  shift
  case "$opt" in
    -[0-9]*)
      if [[ "$opt" =~ ^-?[0-9]+(\.[0-9]+)?$ ]]; then
        delay="${opt#-}"
      else
        echo 1>&2 "$0: $1: unknown option"
        exit 1
      fi
      ;;
    --delay)
      delay="$1"
      shift
      ;;
    --random)
      random=1
      ;;
    --count)
      count="$1"
      shift
      ;;
    line | trickle) method="$opt" ;;
    *)
      echo 1>&2 "$0: $1: unknown option"
      exit 1
      ;;
  esac
done

setup

case "$method" in
  line) method_line ;;
  trickle) method_trickle ;;
  *)
    echo 1>&2 "$0: $1: unknown option"
    exit 1
    ;;
esac
