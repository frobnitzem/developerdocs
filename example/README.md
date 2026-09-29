# Producer+Forwarder Job API Setup

This directory has container builds for the producer
plus lclstream-fastcache programs, combined with a
`psik_api` job server.

Typically you would develop client applications directly against
lclstreamer on psana.

What the `Containerfile.simple` and `Containerfile.producer`
builds provide is `psik_api` that launches the backend processes
just as they would be accessible on the SLAC psana
clusters and data transfer nodes.

The lclstream-api container can interact with this backend
container to provide an API-based way to manage combined
producer+forwarder processes - automating the SLAC-side machinery.

## Installation

Build a simple producer container with

    podman build --network host \
           -f Containerfile.simple \
           -t lclstream-simple .

*or* build the psana2-based producer container with

    podman build --network host \
           -f Containerfile.producer \
           -t lclstream-producer .

Then setup your outer virtual env for development

    python3 -m venv ./venv
    . ./venv/bin/activate

    pip install certified
    certified init --host localhost --host 127.0.0.1 'Test Developer'

The last two steps create a ./venv/etc/certified directory
holding x509 certificates needed to authenticate to the container.

For simplicity, we'll use the same certificate inside and outside
the container (i.e. the server and client use the same identity).
See https://certified.readthedocs.io for more advanced usage.


## Running

Then start the container with `./run.sh`, which prints
the container's id/name.

get the id / check status of the container

    podman ps

run a shell within the container

    podman exec -it <name> bash

stop and delete the running process:

    podman stop <name>; podman rm <name>

Port 4433 exports `psik_api`, authenticated via mTLS.


## Use

The container itself has the following programs:

- lclstreamer: data producer
- fastcache: message forwarder
- psik: test job client for interacting with `psik_api`

From either a venv containing the python `certified` package outside
the container or from within the container, see the job list using:

    message https://localhost:4433/v3/jobs

Run fastcache inside the container:

    lclstream-fastcache <configfile.json>

Run lclstreamer inside the container:

    lclstreamer --num-events 100 --debug --config <parameters.yaml>


