#!/bin/sh
exec env LD_PRELOAD=/usr/lib/libglycin-nosandbox.so /usr/bin/swaybg "$@"
