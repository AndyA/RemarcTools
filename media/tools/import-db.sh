#!/bin/bash

db=remarc
dir="export.$db"
for col in audio images theme video; do
  mongoimport -d "$db" -c "$col" --drop --file "$dir/$col.json"
done

# vim:ts=2:sw=2:sts=2:et:ft=sh

