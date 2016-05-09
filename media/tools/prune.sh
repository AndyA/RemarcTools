#!/bin/bash

incoming="incoming"
output="output"

outabs="$PWD/$output"
cd "$incoming"
find . -type f -not -name '.*' | while read src; do
  dir="$outabs/$( dirname "$src" )"
  base="$( basename "$src" )"
  pat="${base%.*}.*"
  find "$dir" -maxdepth 1 -name "$pat"
done

# vim:ts=2:sw=2:sts=2:et:ft=sh

