"""Live aioquic/ls-qpack oracle with an explicit encoder-stream release barrier.

Uses private hooks in aioquic 1.7.1, pinned by the adjacent aioquic-interop
uv environment. Review those hooks when updating the lock. A field section is sent
before its dynamic insertions; the Rust test releases them only after Rama's
qlog proves it blocked. No timing race is used to manufacture blocking.
"""
import argparse
import asyncio
import json
import sys

from aioquic.asyncio import serve
from aioquic.asyncio.protocol import QuicConnectionProtocol
from aioquic.h3.connection import H3Connection
from aioquic.h3.events import HeadersReceived
from aioquic.quic.configuration import QuicConfiguration


def say(**record):
    print(json.dumps(record), flush=True)


class DelayedEncoder(H3Connection):
    def __init__(self, quic):
        super().__init__(quic)
        self.held = bytearray()
        self.dynamic_requests = 0
        self.pending_dynamic_requests = set()
        self.dynamic_responses = 0

    def _decode_headers(self, stream_id, frame_data):
        if frame_data and frame_data[0] != 0:
            self.pending_dynamic_requests.add(stream_id)
        headers = super()._decode_headers(stream_id, frame_data)
        if stream_id in self.pending_dynamic_requests:
            self.pending_dynamic_requests.remove(stream_id)
            self.dynamic_requests += 1
        return headers

    def _encode_headers(self, stream_id, headers):
        encoder, field = self._encoder.encode(stream_id, headers)
        self._encoder_bytes_sent += len(encoder)
        if field[0] != 0:
            self.dynamic_responses += 1
        if encoder and field[0] != 0:
            self.held.extend(encoder)
        else:
            self._quic.send_stream_data(self._local_encoder_stream_id, encoder)
        return field


async def main(args):
    protocols = []
    failed = asyncio.get_running_loop().create_future()

    class Protocol(QuicConnectionProtocol):
        def __init__(self, *args, **kwargs):
            super().__init__(*args, **kwargs)
            self.http = DelayedEncoder(self._quic)
            protocols.append(self)

        def quic_event_received(self, event):
            try:
                for received in self.http.handle_event(event):
                    if not isinstance(received, HeadersReceived):
                        continue
                    headers = dict(received.headers)
                    assert headers[b"x-dynamic-request"] == b"independent-qpack-" * 24
                    assert not self.http.held, "one barrier at a time"
                    self.http.send_headers(received.stream_id, [
                        (b":status", b"200"),
                        (b"x-dynamic-response", b"independent-qpack-" * 24),
                    ])
                    self.http.send_data(received.stream_id, b"dynamic qpack", end_stream=True)
                    self.transmit()
                    say(event="response", held=bool(self.http.held),
                        dynamic_requests=self.http.dynamic_requests,
                        dynamic_responses=self.http.dynamic_responses)
            except Exception as error:
                say(event="failed", error=repr(error))
                if not failed.done():
                    failed.set_result(error)
                self.close()

    config = QuicConfiguration(is_client=False, alpn_protocols=["h3"])
    config.load_cert_chain(args.cert, args.key)
    server = await serve("127.0.0.1", 0, configuration=config, create_protocol=Protocol)
    say(event="listening", port=server._transport.get_extra_info("sockname")[1])
    try:
        while True:
            order = (await asyncio.to_thread(sys.stdin.readline)).strip()
            if failed.done():
                raise failed.result()
            if order == "release":
                assert len(protocols) == 1
                protocol = protocols[0]
                assert protocol.http.held
                protocol._quic.send_stream_data(
                    protocol.http._local_encoder_stream_id, bytes(protocol.http.held))
                protocol.http.held.clear()
                protocol.transmit()
            elif order == "finish":
                assert len(protocols) == 1
                http = protocols[0].http
                assert http.dynamic_requests > 0 and http.dynamic_responses > 0
                assert http._encoder_bytes_received > 0 and http._decoder_bytes_received > 0
                say(event="complete", encoder_received=http._encoder_bytes_received,
                    decoder_received=http._decoder_bytes_received)
                return
            else:
                raise RuntimeError(f"unexpected control order: {order!r}")
    finally:
        server.close()


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--cert", required=True)
    parser.add_argument("--key", required=True)
    asyncio.run(main(parser.parse_args()))
