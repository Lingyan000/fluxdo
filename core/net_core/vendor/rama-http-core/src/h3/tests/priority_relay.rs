use rama_core::rt::{Executor, spawn};
use rama_http::headers::{HeaderMapExt as _, Priority};
use rama_http_types::{Body, Request, Response, Version};
use std::time::Duration;
use tokio::{sync::oneshot, time::timeout};

use super::{LIMIT, Pair};
use crate::h3::{client, connection::Config, server};

#[tokio::test(start_paused = true)]
async fn early_priority_handle_forwards_updates_before_response_headers() {
    timeout(LIMIT, async {
        let pair = Pair::in_memory(None, None).await;
        let (mut client, driver) =
            client::handshake::<Body, _>(pair.client.clone(), Config::default(), Executor::new())
                .unwrap();
        spawn(driver.run());
        let (mut server, driver) =
            server::handshake(pair.server.clone(), Config::default()).unwrap();
        spawn(driver.run());
        let (tx, rx) = oneshot::channel();
        let mut request = Request::builder()
            .uri("https://localhost/")
            .version(Version::HTTP_3)
            .body(Body::empty())
            .unwrap();
        let initial = Priority::new(5, false).unwrap();
        request.headers_mut().typed_insert(initial);
        let result = spawn(async move {
            client
                .send_request_with_priority(request, move |handle| {
                    tx.send(handle).unwrap();
                })
                .await
        });
        let (request, response) = server.accept().await.unwrap().resolve().await.unwrap();
        let mut observed = response.peer_priority();
        assert_eq!(observed.changed().await.unwrap(), initial);
        let handle = rx.await.unwrap();
        assert!(
            !result.is_finished(),
            "the handle must arrive before a response exists"
        );
        for priority in [
            Priority::new(0, true).unwrap(),
            Priority::new(7, false).unwrap(),
        ] {
            handle.update(priority).unwrap();
            assert_eq!(observed.changed().await.unwrap(), priority);
        }
        timeout(Duration::from_millis(1), observed.changed())
            .await
            .unwrap_err();
        let latest = Priority::new(2, true).unwrap();
        handle.update(latest).unwrap();
        assert_eq!(observed.changed().await.unwrap(), latest);
        drop(request);
        response
            .send_response(Response::new(Body::empty()))
            .await
            .unwrap();
        drop(result.await.unwrap().unwrap());
        pair.close().await;
    })
    .await
    .unwrap();
}

#[tokio::test(start_paused = true)]
async fn priority_observer_reports_connection_close_without_observation_enabled() {
    timeout(LIMIT, async {
        let pair = Pair::in_memory(None, None).await;
        let config = Config::default();
        assert!(config.observation.is_none());
        let (mut client, driver) =
            client::handshake::<Body, _>(pair.client.clone(), config.clone(), Executor::new())
                .unwrap();
        spawn(driver.run());
        let (mut server, driver) = server::handshake(pair.server.clone(), config).unwrap();
        spawn(driver.run());
        let request = spawn(async move {
            client
                .send_request(
                    Request::builder()
                        .uri("https://localhost/")
                        .version(Version::HTTP_3)
                        .body(Body::empty())
                        .unwrap(),
                )
                .await
        });
        let (_body, response) = server.accept().await.unwrap().resolve().await.unwrap();
        let mut observed = response.peer_priority();
        observed.changed().await.unwrap();
        pair.client.close(0u32, b"finished");
        observed.changed().await.unwrap_err();
        drop(response);
        let _request_result = request.await;
        pair.close().await;
    })
    .await
    .unwrap();
}

/// 每次请求使用实际分配的流编号；字段格式保留，但不能突破控制帧预算。
#[tokio::test(start_paused = true)]
async fn sampled_priority_targets_each_new_request_and_rejects_oversized_values() {
    use rama_core::extensions::ExtensionsRef as _;
    use rama_http_types::proto::h3::{control::RequestPriority,observation::H3RequestObservation};
    timeout(LIMIT,async {
        let pair=Pair::in_memory(None,None).await;
        let (mut client,driver)=client::handshake::<Body,_>(pair.client.clone(),Config::default(),Executor::new()).unwrap();
        spawn(driver.run());
        let (mut server,driver)=server::handshake(pair.server.clone(),Config {observation:Some(Default::default()),..Config::default()}).unwrap();
        spawn(driver.run());
        let receiver=spawn(async move {
            let mut streams=Vec::new();
            for _ in 0..3 {
                let (request,response)=server.accept().await.unwrap().resolve().await.unwrap();
                let mut priority=response.peer_priority();
                loop {if priority.changed().await.unwrap()==Priority::new(1,true).unwrap(){break;}}
                streams.push(request.extensions().get_ref::<H3RequestObservation>().unwrap().stream_id);
                response.send_response(Response::new(Body::empty())).await.unwrap();
            }
            streams
        });
        for _ in 0..3 {
            let request=Request::builder().uri("https://localhost/").body(Body::empty()).unwrap();
            request.extensions().insert(RequestPriority("u=1, i".into()));
            drop(client.send_request(request).await.unwrap());
        }
        assert_eq!(receiver.await.unwrap(),vec![0,4,8]);
        let request=Request::builder().uri("https://localhost/").body(Body::empty()).unwrap();
        request.extensions().insert(RequestPriority(vec![b'x';1025].into()));
        assert!(client.send_request(request).await.is_err());
        pair.close().await;
    }).await.unwrap();
}
