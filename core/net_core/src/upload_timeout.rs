//! 对齐 Dio IO 适配器：连接就绪后限制整个请求体提交阶段，而非块间空闲时间。
use std::time::Duration;
use tokio::{sync::watch, time::Instant};

#[derive(Debug, Clone, rama::extensions::Extension)]
pub(crate) struct UploadStarted(pub watch::Sender<Option<Instant>>);

pub(crate) async fn wait(mut started: watch::Receiver<Option<Instant>>, limit: Option<Duration>) {
    let Some(limit) = limit else {
        return std::future::pending().await;
    };
    let at = match started.wait_for(|at| at.is_some()).await {
        Ok(at) => *at,
        // 请求提前结束时不能把通道关闭误判为上传超时。
        Err(_) => None,
    };
    let Some(at) = at else {
        return std::future::pending().await;
    };
    tokio::time::sleep_until(at + limit).await;
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn only_upload_phase_consumes_send_timeout() {
        let (tx, rx) = watch::channel(None);
        let deadline = wait(rx, Some(Duration::from_millis(30)));
        tokio::pin!(deadline);
        assert!(
            tokio::time::timeout(Duration::from_millis(60), &mut deadline)
                .await
                .is_err()
        );
        tx.send_replace(Some(Instant::now()));
        assert!(
            tokio::time::timeout(Duration::from_millis(10), &mut deadline)
                .await
                .is_err()
        );
        tokio::time::timeout(Duration::from_secs(1), deadline)
            .await
            .unwrap();
    }

    #[tokio::test]
    async fn closed_or_disabled_deadline_never_fires() {
        let (tx, rx) = watch::channel(None);
        drop(tx);
        assert!(
            tokio::time::timeout(
                Duration::from_millis(20),
                wait(rx, Some(Duration::from_millis(1)))
            )
            .await
            .is_err()
        );
        let (_tx, rx) = watch::channel(Some(Instant::now()));
        assert!(
            tokio::time::timeout(Duration::from_millis(20), wait(rx, None))
                .await
                .is_err()
        );
    }
}
