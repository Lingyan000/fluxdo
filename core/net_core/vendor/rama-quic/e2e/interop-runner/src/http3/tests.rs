use super::*;
use rama::utils::fs::tempdir;
use std::sync::atomic::{AtomicUsize, Ordering};
use tokio::sync::{Notify, Semaphore};

fn response(status: StatusCode, version: Version) -> Response<Body> {
    Response::builder()
        .status(status)
        .version(version)
        .body(Body::from("download bytes"))
        .unwrap()
}

#[tokio::test]
async fn download_requires_successful_http3_before_creating_a_file() {
    let directory = tempdir().unwrap();
    for (status, version) in [
        (StatusCode::NOT_FOUND, Version::HTTP_3),
        (StatusCode::NO_CONTENT, Version::HTTP_3),
        (StatusCode::OK, Version::HTTP_2),
        (StatusCode::OK, Version::HTTP_11),
    ] {
        store_response(response(status, version), directory.path(), "rejected")
            .await
            .unwrap_err();
        assert!(!directory.path().join("rejected").exists());
    }
    store_response(
        response(StatusCode::OK, Version::HTTP_3),
        directory.path(),
        "accepted",
    )
    .await
    .unwrap();
    assert_eq!(
        tokio::fs::read(directory.path().join("accepted"))
            .await
            .unwrap(),
        b"download bytes"
    );
}

#[tokio::test]
async fn download_refuses_to_overwrite_an_existing_file() {
    let directory = tempdir().unwrap();
    let path = directory.path().join("existing");
    tokio::fs::write(&path, b"keep these bytes").await.unwrap();
    store_response(
        response(StatusCode::OK, Version::HTTP_3),
        directory.path(),
        "existing",
    )
    .await
    .unwrap_err();
    assert_eq!(tokio::fs::read(path).await.unwrap(), b"keep these bytes");
}

#[tokio::test]
async fn server_admission_bounds_ready_requests_until_a_slot_completes() {
    let admitted = Arc::new(AtomicUsize::new(0));
    let ready = Arc::new(Notify::new());
    let overflow = Arc::new(Notify::new());
    let permits = Arc::new(Semaphore::new(0));
    let requests = stream::iter((0..=STREAM_LIMIT).map(Ok)).chain(stream::pending());
    let task = tokio::spawn(run_requests(requests, std::future::pending(), {
        let admitted = admitted.clone();
        let ready = ready.clone();
        let overflow = overflow.clone();
        let permits = permits.clone();
        move |_| {
            let count = admitted.fetch_add(1, Ordering::SeqCst) + 1;
            if count == STREAM_LIMIT {
                ready.notify_one();
            }
            if count > STREAM_LIMIT {
                overflow.notify_one();
            }
            let permits = permits.clone();
            async move {
                let permit = permits.acquire().await.unwrap();
                permit.forget();
                Ok(())
            }
        }
    }));
    tokio::time::timeout(Duration::from_secs(5), ready.notified())
        .await
        .unwrap();
    let admitted_extra = tokio::time::timeout(Duration::from_millis(100), overflow.notified())
        .await
        .is_ok();
    let bounded_count = admitted.load(Ordering::SeqCst);
    permits.add_permits(1);
    tokio::time::timeout(Duration::from_secs(5), async {
        while admitted.load(Ordering::SeqCst) <= STREAM_LIMIT {
            tokio::task::yield_now().await;
        }
    })
    .await
    .unwrap();
    task.abort();
    assert!(task.await.unwrap_err().is_cancelled());
    assert!(
        !admitted_extra,
        "accepted a request with every server slot occupied"
    );
    assert_eq!(bounded_count, STREAM_LIMIT);
}

#[tokio::test]
async fn server_propagates_non_clean_close_at_every_completion_site() {
    for error in [
        H3Error::connection(Code::H3_INTERNAL_ERROR, "driver failure"),
        H3Error::connection(Code::H3_FRAME_ERROR, "malformed frame"),
        H3Error::stream(Code::H3_NO_ERROR, "stream scoped"),
    ] {
        run_requests(
            stream::pending::<Result<(), H3Error>>(),
            async { Err(error) },
            |()| async { Ok(()) },
        )
        .await
        .unwrap_err();
        run_requests(
            stream::once(async { Err::<(), _>(error) }),
            std::future::pending(),
            |()| async { Ok(()) },
        )
        .await
        .unwrap_err();
        run_requests(
            stream::once(async { Ok(()) }).chain(stream::pending()),
            std::future::pending(),
            move |()| async move { Err(error.into()) },
        )
        .await
        .unwrap_err();
    }
    let clean = H3Error::connection(Code::H3_NO_ERROR, "finished");
    run_requests(
        stream::pending::<Result<(), H3Error>>(),
        async { Err(clean) },
        |()| async { Ok(()) },
    )
    .await
    .unwrap();
    run_requests(
        stream::once(async { Err::<(), _>(clean) }),
        std::future::pending(),
        |()| async { Ok(()) },
    )
    .await
    .unwrap();
    run_requests(
        stream::once(async { Ok(()) }).chain(stream::pending()),
        std::future::pending(),
        move |()| async move { Err(clean.into()) },
    )
    .await
    .unwrap();
}
