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

    pip install certified psik
    certified init --host localhost --host 127.0.0.1 'Test Developer'

The last two steps create a ./venv/etc/certified directory
holding x509 certificates needed to authenticate to the container.

For simplicity, we'll use the same certificate inside and outside
the container (i.e. the server and client use the same identity).
See https://certified.readthedocs.io for more advanced usage.

## Running

Then start the container with `./producer.sh`, which prints
the container's id/name.

get the id / check status of the container

    podman ps

run a shell within the container

    podman exec -it <name> bash

stop and delete the running process:

    podman stop <name>; podman rm <name>

Port 4433 exports `psik_api`, authenticated via mTLS.

For the simple, end-to-end working example, skip to Step 4 of
the tutorial.

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

For a test `parameters.yaml` sending random arrays,
use `lclstreamer-internal.yaml`.

## Tutorial

### Step 1: Run a producer inside the container

From inside the container, paste the included `lclstreamer-internal.yaml`
file into `lclstreamer.yaml`,

    cat >lclstreamer.yaml <<.
    (contents here)
    .

Then run the producer

    lclstreamer

You should see,

    [15:12:23] INFO     Rank: 0 on 29b95fc3f7e1 ->
                        ['tcp://127.0.0.1:42001']

Pull the data from outside the container,

    lclstream pull -vv -d tcp://127.0.0.1:42001 | tar tf -

Now look closely at the configuration's output block:

    type: BinaryDataStreamingDataHandler
    urls:
        - "tcp://0.0.0.0:42001"
    distribute: False
    buffer: 0
    role: server
    library: zmq
    socket_type: push

The server role causes it to listen for client connections,
and binding to 0.0.0.0 (all addresses) is required because
it's running inside the container. The container's port binding
maps those to 127.0.0.1, so it's still limited to localhost.

When running with lclstream-fastcache, the data producer
needs to be run instead as a client.  The cache is a server
on both sides, so the producer and consumer both act as
clients connecting to it.

These details are important if you are manually launching
the fastcache process. They are not essential if you use
`lclstream_api` to launch the producer and cache, since
it replaces the producer's output block with a client, and
directs that client to send its messages to the cache.


### Step 2: Run a producer from outside the container

This step will use the /app/lclstreamer/lclstreamer.yaml
file you created inside the container in the last step,
but run the producer job without running the container itself.

    psik run --config psik.json lclstreamer_job.yaml

You can make your psik config. file default to psik.json
by copying it to `$VIRTUAL_ENV/etc/psik.json`.

As before, capture the data with (on the host):

    lclstream pull -vv -d tcp://127.0.0.1:42001 | tar tf -

The `lclstreamer_job.yaml` file is a psik JobSpec. Its backend
targets job API running in the container, as defined in `psik.json`.
Since we don't have an API listening for callbacks on the job's
progress, you will need to run `psik poll <jobid>` to pull job
status and output information to your local job tracking directory.

```
example% psik ls 1791299205.043
lclstreamer_test
    base: /tmp/psik/1791299205.043
    work: /tmp/psik/1791299205.043/work

    time ndx state info
    1791299205.051   0        new {"backend":{"type":"psik","attributes":{"remote_url":"https://localhost:4433","remote_backend":"default","next":"{}"}}}
    1791299205.070   1     queued 1791299205.090

example% psik poll 1791299205.043
x updated=1791299205.0936468 jobndx=0 state=<JobState.new: 'new'> info='{}'
x updated=1791299205.112402 jobndx=1 state=<JobState.queued: 'queued'> info='9'
- updated=1791299205.1306698 jobndx=1 state=<JobState.active: 'active'> info=''
- updated=1791299205.1749732 jobndx=1 state=<JobState.completed: 'completed'> info=''
+ Updating stderr.1: 0 bytes
+ Updating console.1: 338 bytes
+ Updating stdout.1: 62 bytes
Final file download not implemented.
lclstreamer_test
    base: /tmp/psik/1791299205.043
    work: /tmp/psik/1791299205.043/work

    time ndx state info
    1791299205.051   0        new {"backend":{"type":"psik","attributes":{"remote_url":"https://localhost:4433","remote_backend":"default","next":"{}"}}}
    1791299205.070   1     queued 1791299205.090
    1791299205.131   1     active
    1791299205.175   1  completed
```

The console.1 and stdout.1 files are the remote (container's) job
log outputs.

### Step 3: Run a producer + forwarder process from the API

Build the lclstream-api container using the instructions
included in containers/README.md from the
[lclstream-api repo](https://github.com/lclstream/lclstream_api).

Start the container with `api.sh`, which prints the container's id.
Then, outside the container, send a request for a data stream,

    message -X POST https://127.0.0.1:8000/v1/transfers --yaml lclstreamer-internal.yaml

You should get a response with the address to receive your data.
Substitute that address below if it differs:

    lclstream pull -v -d tcp://127.0.0.1:42100 | tar tf -

### Step 4: Run a producer+forwarder+receiver process in one shot

The lclstream client application also contains a receiver
that both requests a transfer, then pulls the result,

    lclstream get --mtls --server https://localhost:8000 \
                  lclstreamer-internal.yaml | tar tf -

