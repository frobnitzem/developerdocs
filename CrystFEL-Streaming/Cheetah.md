# Cheetah
The following data block in Cheetah performs the streaming to CrystFEL:

[https://github.com/omdevteam/om/blob/c965f59ac56165815ce84934d017366218fd9403/src/om/processing\_layer/cheetah.py#L1277-L1304](https://github.com/omdevteam/om/blob/c965f59ac56165815ce84934d017366218fd9403/src/om/processing_layer/cheetah.py#L1277-L1304) 

```python
		# Stream hits to CrystFEL
        if received_data["frame_is_hit"]:
            # Wait for a request to the responding socket.
            while len(self._request_list) == 0:
                self._handle_external_requests()

            last_request: tuple[bytes, bytes] = self._request_list[-1]
            data_to_send: Any = (  # pyright: ignore[reportUnknownVariableType]
                msgpack.packb(  # pyright: ignore[reportUnknownMemberType]
                    {
                        "detector_data": received_data["detector_data"],
                        "peak_list": asdict(received_data["peak_list"]),
                        "beam_energy": received_data["beam_energy"],
                        "detector_distance": received_data["detector_distance"],
                        "event_id": received_data["event_id"],
                        "timestamp": received_data["timestamp"],
                        "source": self._source,
                        "configuration_file": str(self._configuration_file),
                        "optical_laser_active": received_data["optical_laser_active"],
                    },
                    use_bin_type=True,
                )
            )
            self._responding_socket.send_data(
                identity=last_request[0],
                message=data_to_send,  # pyright: ignore[reportUnknownArgumentType]
            )
            _ = self._request_list.pop()

```

This code instantiates the responding socket in Cheetah

[https://github.com/omdevteam/om/blob/c965f59ac56165815ce84934d017366218fd9403/src/om/lib/zmq.py#L177-L200](https://github.com/omdevteam/om/blob/c965f59ac56165815ce84934d017366218fd9403/src/om/lib/zmq.py#L177-L200)

```python
        if responding_url is None:
            responding_url = f"tcp://{get_current_machine_ip()}:12322"

        self._blocking: bool = blocking
        # Sets a high water mark of 1 (A messaging queue that is 1 message long, so no
        # queuing).
        self._context: Any = zmq.Context()
        self._sock: Any = self._context.socket(zmq.ROUTER)
        self._sock.set_hwm(1)
        try:
            self._sock.bind(responding_url)
        except zmq.error.ZMQError as exc:
            # TODO: fix_types
            exc_type, exc_value = sys.exc_info()[:2]
            if exc_type is not None:
                raise OmInvalidZmqUrl(
                    "The setup of the data requesting socket failed. The requested"
                    "URL is not valid due to the following reason: "
                    f"{exc_type.__name__}: {exc_value}."
                ) from exc

        self._zmq_poller: Any = zmq.Poller()
        self._zmq_poller.register(self._sock, zmq.POLLIN)
        log.info(f"Answering requests at {responding_url}")
```

The system received requests. If CrystFEL's request is `next`, the request is queued and satisfied by the code above

[https://github.com/omdevteam/om/blob/c965f59ac56165815ce84934d017366218fd9403/src/om/processing\_layer/cheetah.py#L1402](https://github.com/omdevteam/om/blob/c965f59ac56165815ce84934d017366218fd9403/src/om/processing_layer/cheetah.py#L1402)

```
        request: tuple[bytes, bytes] | None = self._responding_socket.get_request()
        if request:
            if request[1] == b"next":
                self._request_list.append(request)
            else:
                log_warning(
                    f"OM Warning: Could not understand request '{str(request[1])}'."
                )
                self._responding_socket.send_data(identity=request[0], message=b"What?")
```

The request is analyzed at each iteration of Cheetah. If CrystFEL requests matches `next`