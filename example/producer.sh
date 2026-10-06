#!/bin/bash
# Start the producer container, binding in a local identity
# Note the published port ranges are for:
#  4433 - psik_api server
#  42001-42100 - lclstream transfers, which must match the range
#                defined in lclstream_api.yaml

VIRTUAL_ENV="${VIRTUAL_ENV:-./venv}"
CERTIFIED_CONFIG="${CERTIFIED_CONFIG:-$VIRTUAL_ENV/etc/certified}"

if ! [ -d "$CERTIFIED_CONFIG" ]; then
    echo "You must setup a venv and an identity via 'certified init',"
    echo "either in \$VIRTUAL_ENV/etc/certified (default) or by setting \$CERTIFIED_CONFIG"
    exit 1
fi

image="localhost/lclstream-producer"
image="localhost/lclstream-simple"

#podman run -p 127.0.0.1:4433:4433 \
#           -p 127.0.0.1:42001-42100:42001-42100 \
podman run --network host \
           -v "$CERTIFIED_CONFIG:/etc/certified" \
           -d "$image"
