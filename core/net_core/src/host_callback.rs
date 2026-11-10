//! Dart 回调只在创建它的 isolate 存活期间有效。
//! 清除回调必须与调用互斥：仅复制锁内指针、锁外调用仍会与热重启竞态。

use parking_lot::Mutex;

pub(crate) struct HostCallback<T> {
    callback: Mutex<Option<T>>,
}

impl<T: Copy> HostCallback<T> {
    pub(crate) const fn new() -> Self {
        Self {
            callback: Mutex::new(None),
        }
    }

    /// 返回时，旧回调已没有正在执行的原生调用。
    pub(crate) fn set(&self, callback: Option<T>) {
        *self.callback.lock() = callback;
    }

    /// NativeCallable.listener 只异步投递，不同步重入宿主；整个投递期间持锁。
    pub(crate) fn with<R>(&self, invoke: impl FnOnce(T) -> R) -> Option<R> {
        let callback = self.callback.lock();
        callback.map(invoke)
    }
}

#[cfg(test)]
pub(crate) static TEST_HOST_LOCK: Mutex<()> = Mutex::new(());

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::{Arc, mpsc};
    use std::time::Duration;

    #[test]
    fn detach_waits_for_in_flight_invocation_and_allows_new_host() {
        let slot = Arc::new(HostCallback::new());
        slot.set(Some(1));
        let (entered_tx, entered_rx) = mpsc::channel();
        let (release_tx, release_rx) = mpsc::channel();
        let worker_slot = slot.clone();
        let worker = std::thread::spawn(move || {
            worker_slot.with(|value| {
                assert_eq!(value, 1);
                entered_tx.send(()).unwrap();
                release_rx.recv_timeout(Duration::from_secs(5)).unwrap();
            });
        });
        entered_rx.recv_timeout(Duration::from_secs(5)).unwrap();
        // 与清理路径使用同一把锁；在途投递结束前，清理不能取得它。
        assert!(slot.callback.try_lock().is_none());
        let (detached_tx, detached_rx) = mpsc::channel();
        let detach_slot = slot.clone();
        let detach = std::thread::spawn(move || {
            detach_slot.set(None);
            detached_tx.send(()).unwrap();
        });
        assert!(detached_rx.recv_timeout(Duration::from_millis(30)).is_err());
        release_tx.send(()).unwrap();
        detached_rx.recv_timeout(Duration::from_secs(5)).unwrap();
        worker.join().unwrap();
        detach.join().unwrap();
        assert!(slot.with(|_| panic!("detached callback invoked")).is_none());
        slot.set(Some(2));
        assert_eq!(slot.with(|value| value), Some(2));
    }
}
