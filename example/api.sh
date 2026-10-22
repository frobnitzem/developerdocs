#!/bin/bash
# Start the lclstream-api container, binding in a local identity.
# Note the --network host is needed so that this container
# can talk to the producer container as localhost:4433.

VIRTUAL_ENV="${VIRTUAL_ENV:-./venv}"
CERTIFIED_CONFIG="${CERTIFIED_CONFIG:-$VIRTUAL_ENV/etc/certified}"

if ! [ -d "$CERTIFIED_CONFIG" ]; then
    echo "You must setup a venv and an identity via 'certified init',"
    echo "either in \$VIRTUAL_ENV/etc/certified (default) or by setting \$CERTIFIED_CONFIG"
    exit 1
fi

image="localhost/lclstream-api"

podman run --network host \
           -v "$CERTIFIED_CONFIG:/etc/certified" \
           -d "$image" \
           certified serve lclstream_api.server:app \
           https://localhost:8000
