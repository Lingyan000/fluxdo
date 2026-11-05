use std::pin::pin;

use rama_core::{
    Service,
    futures::{StreamExt as _, stream::FuturesUnordered},
    rt::Executor,
    telemetry::tracing::{self, Instrument as _},
};
use rama_net::address::SocketAddress;

use super::Endpoint;
use crate::driver::{connection::Connection, incoming::IncomingOutcome};

impl Endpoint {
    /// Serve incoming connections with `service`, each in its own task spawned on `exec`.
    ///
    /// The handshake runs in that task, so a slow peer never delays the next accept; see
    /// [`Incoming::accept_or_retry`](crate::Incoming::accept_or_retry) for when it starts
    /// with a Retry. Each established [`Connection`] carries its [`SocketInfo`](rama_net::stream::SocketInfo)
    /// in its extensions.
    ///
    /// Once the guard of a graceful `exec` is cancelled, new connection attempts are refused,
    /// and so are attempts still in their handshake, while established connections keep
    /// running, so their protocol can drain (HTTP/3 sends GOAWAY and finishes in-flight
    /// requests). When the last one ends, the endpoint is
    /// closed and shut down. Build the endpoint on an executor without that guard: one that
    /// carries it closes every connection as soon as shutdown starts.
    ///
    /// Returns when the endpoint is closed, or after cancellation once served connections ended.
    pub async fn serve<S>(self, exec: Executor, service: S)
    where
        S: Service<Connection> + Clone,
    {
        let guard = exec.guard().cloned();
        let mut cancelled = pin!(async move {
            match guard {
                Some(guard) => guard.cancelled().await,
                None => std::future::pending().await,
            }
        });
        let mut served = FuturesUnordered::new();

        loop {
            tokio::select! {
                () = cancelled.as_mut() => {
                    tracing::trace!("signal received: initiate graceful shutdown");
                    break;
                }
                Some(served) = served.next(), if !served.is_empty() => log_join(served),
                incoming = self.accept() => {
                    let Some(incoming) = incoming else {
                        break;
                    };
                    let service = service.clone();
                    let peer_addr = incoming.remote_address();
                    let local_addr = incoming.local_address().map(SocketAddress::from);
                    let trace_local_addr =
                        local_addr.unwrap_or_else(|| SocketAddress::default_ipv4(0));
                    let span = tracing::trace_root_span!(
                        "quic::serve_graceful",
                        otel.kind = "server",
                        network.local.port = trace_local_addr.port,
                        network.local.address = %trace_local_addr.ip_addr,
                        network.peer.port = %peer_addr.port(),
                        network.peer.address = %peer_addr.ip(),
                        network.protocol.name = "quic",
                    );
                    // A handshake has nothing to drain: one still running when shutdown begins
                    // is refused, as a new attempt is, instead of holding the shutdown until the
                    // client finishes or the attempt times out.
                    let shutting_down = exec.guard().map(|guard| guard.clone_weak());
                    served.push(exec.spawn_task(
                        async move {
                            let outcome = match &shutting_down {
                                Some(shutting_down) => {
                                    incoming.accept_or_retry_until(shutting_down.cancelled()).await
                                }
                                None => incoming.accept_or_retry().await,
                            };
                            let connection = match outcome {
                                Ok(IncomingOutcome::Accepted(connection)) => connection,
                                Ok(IncomingOutcome::Retried) => {
                                    tracing::trace!("QUIC: Retry sent");
                                    return;
                                }
                                Err(error) => {
                                    tracing::debug!(%error, "QUIC handshake failed");
                                    return;
                                }
                            };
                            _ = service.serve(connection).await;
                        }
                        .instrument(span),
                    ));
                }
            }
        }

        // Refuse new attempts, so their clients fall back at once, while served connections drain.
        while !served.is_empty() {
            tokio::select! {
                Some(served) = served.next() => log_join(served),
                Some(incoming) = self.accept() => incoming.refuse(),
            }
        }

        _ = self.shutdown().await;
    }
}

fn log_join(served: Result<(), tokio::task::JoinError>) {
    if let Err(error) = served
        && error.is_panic()
    {
        tracing::error!(%error, "QUIC connection service panicked");
    }
}
