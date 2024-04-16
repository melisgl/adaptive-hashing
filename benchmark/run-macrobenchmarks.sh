#!/bin/sh
source ./macrobenchmark.sh --command-names "0 1 u f m s 2 3" \
       ~/src/sbcl.0 ~/src/sbcl.1 ~/src/sbcl.u ~/src/sbcl.f ~/src/sbcl.m \
       ~/src/sbcl.s ~/src/sbcl.2 ~/src/sbcl.3 | tee -a macrobenchmark.log
