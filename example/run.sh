#!/bin/bash
# Start the producer container, binding in a local identity

VIRTUAL_ENV="${VIRTUAL_ENV:-./venv}"
CERTIFIED_CONFIG="${CERTIFIED_CONFIG:-$VIRTUAL_ENV/etc/certified}"

if ! [ -d $CERTIFIED_CONFIG ]; then
    echo "You must setup a venv and an identity via 'certified init',"
    echo "either in \$VIRTUAL_ENV/etc/certified (default) or by setting \$CERTIFIED_CONFIG"
    exit 1
fi

podman run -p 127.0.0.1:4433:4433 -v $CERTIFIED_CONFIG:/etc/certified \
           -d lclstream-producer
