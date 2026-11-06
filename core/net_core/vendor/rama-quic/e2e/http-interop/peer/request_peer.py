"""Independent HTTP/3 client: concurrent uploads, responses and trailers on one connection."""
import argparse
import asyncio
import json

from aioquic.asyncio import connect
from aioquic.asyncio.protocol import QuicConnectionProtocol
from aioquic.h3.connection import H3Connection
from aioquic.h3.events import DataReceived, HeadersReceived
from aioquic.quic.configuration import QuicConfiguration
from aioquic.quic.events import ConnectionTerminated, ProtocolNegotiated


def payload(index):
    return bytes((offset + index) % 251 for offset in range(131072 + index))


class Client(QuicConnectionProtocol):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)
        self.http = H3Connection(self._quic)
        self.requests = {}
        self.alpn = None

    def quic_event_received(self, event):
        if isinstance(event, ProtocolNegotiated):
            self.alpn = event.alpn_protocol
        if isinstance(event, ConnectionTerminated):
            for future, _, _ in self.requests.values():
                if not future.done():
                    future.set_exception(RuntimeError(f"premature close: {event}"))
        for received in self.http.handle_event(event):
            if not isinstance(received, (HeadersReceived, DataReceived)):
                continue
            future, headers, body = self.requests[received.stream_id]
            if isinstance(received, HeadersReceived):
                headers.append(received.headers)
            else:
                body.extend(received.data)
                if len(body) > 262144:
                    raise RuntimeError("response exceeds test bound")
            if received.stream_ended and not future.done():
                future.set_result((headers, body))

    async def request(self, index, port):
        stream = self._quic.get_next_available_stream_id()
        future = asyncio.get_running_loop().create_future()
        self.requests[stream] = (future, [], bytearray())
        data = payload(index)
        self.http.send_headers(stream, [
            (b":method", b"POST"), (b":scheme", b"https"),
            (b":authority", f"localhost:{port}".encode()),
            (b":path", f"/echo/{index}".encode()),
            (b"x-dynamic-request", b"independent-qpack-" * 24),
        ])
        for offset in range(0, len(data), 4096):
            self.http.send_data(stream, data[offset:offset + 4096], end_stream=False)
        self.http.send_headers(stream, [(b"x-upload-complete", b"yes")], end_stream=True)
        self.transmit()
        headers, response = await future
        assert len(headers) == 2, headers
        assert dict(headers[0])[b":status"] == b"200"
        assert dict(headers[0])[b"x-dynamic-response"] == b"independent-qpack-" * 24
        assert dict(headers[1]) == {b"x-download-complete": b"yes"}
        assert response == data
        del self.requests[stream]


async def main(args):
    config = QuicConfiguration(is_client=True, alpn_protocols=["h3"])
    config.server_name = "localhost"
    config.load_verify_locations(args.ca)
    async with connect("127.0.0.1", args.port, configuration=config,
                       create_protocol=Client) as client:
        await asyncio.wait_for(asyncio.gather(
            *(client.request(index, args.port) for index in range(4))), 20)
        # Reuse after all concurrent streams finish, with warmed QPACK state.
        await asyncio.wait_for(client.request(4, args.port), 10)
        assert client.alpn == "h3", client.alpn
        print(json.dumps({"alpn": client.alpn, "requests": 5}), flush=True)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--ca", required=True)
    parser.add_argument("--port", type=int, required=True)
    asyncio.run(main(parser.parse_args()))
