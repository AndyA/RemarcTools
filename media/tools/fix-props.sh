#!/bin/bash

for dir in "$@"; do
  find "$dir" -name '*.properties' | while read props; do
    echo "$props"
    out="$props.out"
    unrtf --text "$props" | tail -n+6 > "$out" && echo >> "$out" && mv "$out" "$props"
  done
done

# vim:ts=2:sw=2:sts=2:et:ft=sh

