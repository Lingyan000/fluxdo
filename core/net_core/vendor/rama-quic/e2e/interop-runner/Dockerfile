# syntax=docker/dockerfile:1
FROM rust:1.96-bookworm@sha256:a339861ae23e9abb272cea45dfafde21760d2ce6577a70f8a926153677902663 AS builder

RUN apt-get update && apt-get install -y --no-install-recommends cmake clang libclang-dev && rm -rf /var/lib/apt/lists/*

WORKDIR /src
COPY . .
ARG TARGETARCH
ARG TLS_BACKEND=boring
# Separate platform caches and serialize concurrent writers to each cache.
RUN --mount=type=cache,id=quic-interop-registry-${TARGETARCH},target=/usr/local/cargo/registry,sharing=locked \
    --mount=type=cache,id=quic-interop-git-${TARGETARCH},target=/usr/local/cargo/git,sharing=locked \
    --mount=type=cache,id=quic-interop-target-${TARGETARCH},target=/build,sharing=locked \
    CARGO_TARGET_DIR=/build cargo build --locked --release --no-default-features --features ${TLS_BACKEND} \
      --manifest-path rama-quic/e2e/interop-runner/Cargo.toml --bins && \
    mkdir /out && \
    cp /build/release/rama-quic-interop-client /build/release/rama-quic-interop-server /out/

FROM martenseemann/quic-network-simulator-endpoint@sha256:3b2b9e6fa317da238c8140a7b6d2bf8d4d45a8464b873eecac3ff2a32520b71a

ARG TLS_BACKEND=boring

LABEL org.opencontainers.image.title="Rama QUIC interop endpoints" \
      org.opencontainers.image.source="https://github.com/plabayo/rama" \
      org.opencontainers.image.licenses="MIT OR Apache-2.0" \
      org.ramaproxy.quic.tls-backend="${TLS_BACKEND}"

COPY --from=builder /out/ /usr/local/bin/
COPY LICENSE-MIT LICENSE-APACHE /usr/share/licenses/rama/
COPY docs/thirdparty/fork/licenses/quinn/ /usr/share/licenses/rama/quinn/
COPY --chmod=755 rama-quic/e2e/interop-runner/run_endpoint.sh /run_endpoint.sh

# Routing setup requires the simulator's NET_ADMIN capability.
ENTRYPOINT ["/run_endpoint.sh"]
