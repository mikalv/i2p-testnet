#!/usr/bin/env bash

DATA="`pwd`/data"

for i in `ls -1 $DATA`; do
  if [ -f "$DATA/$i/router.info" ]; then
    cp "$DATA/$i/router.info" "$DATA/reseed/netDb/routerInfo-$i.dat"
  fi
done
