use rama_core::Layer;
use rama_inspect::storage::{FileStore, MemoryStore, StorageLimits, test_utils::exercise};
use tokio::io::{AsyncSeekExt, AsyncWriteExt};

use super::*;

#[tokio::test]
async fn encrypted_memory_streaming_cancel_concurrency_and_retention() {
    exercise(EncryptStorageLayer::new([42; 32]).layer(MemoryStore::new(StorageLimits::default())))
        .await;
}

#[tokio::test]
async fn encrypted_file_streaming_cancel_concurrency_and_retention() {
    exercise(
        EncryptStorageLayer::new([42; 32])
            .layer(FileStore::temporary(StorageLimits::default()).unwrap()),
    )
    .await;
}

#[tokio::test]
async fn encryption_rejects_tampering_before_exposing_the_chunk() {
    let files = FileStore::temporary(StorageLimits::default()).unwrap();
    let store = EncryptStorageLayer::new([42; 32]).layer(files.clone());
    let collection = store.serve(CreateCollection { id: 1 }).await.unwrap();
    let id = collection
        .append(std::io::Cursor::new(b"secret content"))
        .await
        .unwrap();
    let path = files.directory().join("collection-1.capture");
    let disk = tokio::fs::read(&path).await.unwrap();
    assert!(!disk.windows(6).any(|chunk| chunk == b"secret"));
    let mut file = tokio::fs::OpenOptions::new()
        .write(true)
        .open(path)
        .await
        .unwrap();
    file.seek(std::io::SeekFrom::Start(56)).await.unwrap();
    file.write_all(&[disk[56] ^ 1]).await.unwrap();
    file.flush().await.unwrap();
    let mut plaintext = Vec::new();
    collection
        .read(id)
        .await
        .unwrap()
        .read_to_end(&mut plaintext)
        .await
        .unwrap_err();
    assert!(plaintext.is_empty());
}

#[tokio::test]
async fn encryption_rejects_substitution_reordered_chunks_and_missing_terminators() {
    let files = FileStore::temporary(StorageLimits::default()).unwrap();
    let store = EncryptStorageLayer::new([42; 32]).layer(files.clone());
    let collection = store.serve(CreateCollection { id: 1 }).await.unwrap();
    let first = collection
        .append(std::io::Cursor::new(vec![
            1u8;
            rama_utils::octets::kib(128)
        ]))
        .await
        .unwrap();
    let second = collection
        .append(std::io::Cursor::new(vec![
            2u8;
            rama_utils::octets::kib(128)
        ]))
        .await
        .unwrap();
    let path = files.directory().join("collection-1.capture");
    let original = tokio::fs::read(&path).await.unwrap();
    let record_len = original.len() / 2;
    let mut substituted = original.clone();
    substituted[..record_len].copy_from_slice(&original[record_len..]);
    tokio::fs::write(&path, &substituted).await.unwrap();
    let mut bytes = Vec::new();
    collection
        .read(first)
        .await
        .unwrap()
        .read_to_end(&mut bytes)
        .await
        .unwrap_err();
    assert!(bytes.is_empty());
    let frame_len = 32 + rama_utils::octets::kib(64);
    let mut reordered = original.clone();
    reordered[24..24 + frame_len].copy_from_slice(&original[24 + frame_len..24 + 2 * frame_len]);
    reordered[24 + frame_len..24 + 2 * frame_len].copy_from_slice(&original[24..24 + frame_len]);
    tokio::fs::write(&path, reordered).await.unwrap();
    collection
        .read(first)
        .await
        .unwrap()
        .read_to_end(&mut bytes)
        .await
        .unwrap_err();
    assert!(bytes.is_empty());
    tokio::fs::write(&path, &original[..original.len() - 32])
        .await
        .unwrap();
    collection
        .read(second)
        .await
        .unwrap()
        .read_to_end(&mut bytes)
        .await
        .unwrap_err();
}

#[tokio::test]
async fn authenticated_prefix_does_not_claim_complete_record_integrity() {
    let files = FileStore::temporary(StorageLimits::default()).unwrap();
    let store = EncryptStorageLayer::new([42; 32]).layer(files.clone());
    let collection = store.serve(CreateCollection { id: 1 }).await.unwrap();
    let id = collection
        .append(std::io::Cursor::new(b"authenticated prefix"))
        .await
        .unwrap();
    let path = files.directory().join("collection-1.capture");
    let file = tokio::fs::OpenOptions::new()
        .write(true)
        .open(&path)
        .await
        .unwrap();
    let length = file.metadata().await.unwrap().len();
    file.set_len(length - 1).await.unwrap();
    let mut prefix = collection
        .serve(ReadRecord {
            id,
            range: Some(0..5),
        })
        .await
        .unwrap();
    let mut bytes = Vec::new();
    prefix.read_to_end(&mut bytes).await.unwrap();
    assert_eq!(bytes, b"authe");
    // A clean EOF clamps range bounds; a missing authenticated terminator must
    // still fail while discarding the prefix of an out-of-bounds read.
    match collection
        .serve(ReadRecord {
            id,
            range: Some(100..200),
        })
        .await
    {
        Ok(_) => panic!("truncated ciphertext accepted as a clean EOF"),
        Err(error) => assert_eq!(
            error.downcast_ref::<std::io::Error>().unwrap().kind(),
            std::io::ErrorKind::UnexpectedEof,
        ),
    }
    bytes.clear();
    collection
        .read(id)
        .await
        .unwrap()
        .read_to_end(&mut bytes)
        .await
        .unwrap_err();
}
