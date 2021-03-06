#!/bin/bash

db=remarc
dir="export.$db"
mkdir -p "$dir"
for col in audio images theme video; do
  mongoexport -d "$db" -c "$col" --out "$dir/$col.json"
done

# vim:ts=2:sw=2:sts=2:et:ft=sh

