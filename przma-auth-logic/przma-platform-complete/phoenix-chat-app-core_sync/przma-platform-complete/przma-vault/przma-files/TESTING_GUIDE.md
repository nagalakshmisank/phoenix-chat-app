# Testing Guide - PRZMA Files Service

## Unit Tests

Run tests with:
```bash
cd przma-vault/przma-files
cargo test
```

## Manual Verification

### 1. Basic File Creation & Retrieval

```rust
#[tokio::test]
async fn test_file_lifecycle() -> Result<(), Box<dyn std::error::Error>> {
    let temp = tempfile::tempdir()?;
    let service = FilesService::new(
        temp.path().to_str().unwrap(),
        "did:web:test.com"
    ).await?;

    // Create file
    let content = b"Hello, World!";
    let file = service.add_file(
        "test.txt".to_string(),
        "/docs/".to_string(),
        Space::Core,
        "text/plain".to_string(),
        content,
    ).await?;

    assert_eq!(file.name, "test.txt");
    assert_eq!(file.size_bytes, content.len() as i64);
    assert!(file.content_cas.starts_with("cas:"));
    assert_eq!(file.upload_status, "complete");

    // Retrieve file
    let (record, bytes) = service.get_file(&file.id, &Space::Core).await?;
    assert_eq!(bytes, content);
    assert_eq!(record.id, file.id);

    // Delete file
    service.delete_file(&file.id, &Space::Core).await?;

    // Verify deletion
    let result = service.get_file(&file.id, &Space::Core).await;
    assert!(result.is_err());

    Ok(())
}
```

### 2. Three-Space Testing

```rust
#[tokio::test]
async fn test_three_spaces() -> Result<(), Box<dyn std::error::Error>> {
    let temp = tempfile::tempdir()?;
    let service = FilesService::new(
        temp.path().to_str().unwrap(),
        "did:web:alice.com"
    ).await?;

    // Core (private)
    let core_file = service.add_file(
        "private.txt".to_string(), "/".to_string(),
        Space::Core, "text/plain".to_string(), b"Private",
    ).await?;
    assert_eq!(core_file.is_public, false);
    let pending = service.store.pending_syncs().await?;
    assert_eq!(pending.len(), 0);  // Core doesn't queue

    // Commons (public)
    let commons_file = service.add_file(
        "public.txt".to_string(), "/".to_string(),
        Space::Commons, "text/plain".to_string(), b"Public",
    ).await?;
    assert_eq!(commons_file.is_public, true);
    let pending = service.store.pending_syncs().await?;
    assert_eq!(pending.len(), 1);  // Commons queued

    // Circle (group)
    let circle_file = service.add_file(
        "shared.txt".to_string(), "/".to_string(),
        Space::Circle("circle:team.com".to_string()),
        "text/plain".to_string(),
        b"Shared",
    ).await?;
    let pending = service.store.pending_syncs().await?;
    assert_eq!(pending.len(), 2);  // Circle queued

    Ok(())
}
```

### 3. CAS Deduplication

```rust
#[tokio::test]
async fn test_cas_deduplication() -> Result<(), Box<dyn std::error::Error>> {
    let temp = tempfile::tempdir()?;
    let service = FilesService::new(
        temp.path().to_str().unwrap(),
        "did:web:bob.com"
    ).await?;

    let content = b"Identical content";

    // Add file 1
    let file1 = service.add_file(
        "file1.txt".to_string(), "/".to_string(),
        Space::Core, "text/plain".to_string(), content,
    ).await?;

    // Add file 2 with same content
    let file2 = service.add_file(
        "file2.txt".to_string(), "/".to_string(),
        Space::Core, "text/plain".to_string(), content,
    ).await?;

    // Same CAS URI = same blob = deduplication
    assert_eq!(file1.content_cas, file2.content_cas);
    
    // Verify content is identical
    let (_, bytes1) = service.get_file(&file1.id, &Space::Core).await?;
    let (_, bytes2) = service.get_file(&file2.id, &Space::Core).await?;
    assert_eq!(bytes1, bytes2);
    assert_eq!(bytes1, content);

    Ok(())
}
```

### 4. Sync Queue Operations

```rust
#[tokio::test]
async fn test_sync_queue() -> Result<(), Box<dyn std::error::Error>> {
    let temp = tempfile::tempdir()?;
    let service = FilesService::new(
        temp.path().to_str().unwrap(),
        "did:web:charlie.com"
    ).await?;

    // Add Commons file (queued for sync)
    let file = service.add_file(
        "photo.jpg".to_string(), "/photos/".to_string(),
        Space::Commons, "image/jpeg".to_string(), b"JPEG data",
    ).await?;

    // Check pending
    let pending = service.store.pending_syncs().await?;
    assert_eq!(pending.len(), 1);
    let entry = &pending[0];
    assert_eq!(entry.file_id, file.id);
    assert_eq!(entry.status, "pending");
    assert_eq!(entry.space, "commons");

    // Mark synced
    service.store.mark_synced(&entry.id).await?;

    // Verify no longer pending
    let pending = service.store.pending_syncs().await?;
    assert_eq!(pending.len(), 0);

    Ok(())
}
```

### 5. List with Filters

```rust
#[tokio::test]
async fn test_list_files() -> Result<(), Box<dyn std::error::Error>> {
    let temp = tempfile::tempdir()?;
    let service = FilesService::new(
        temp.path().to_str().unwrap(),
        "did:web:diana.com"
    ).await?;

    // Add multiple files
    service.add_file(
        "doc1.pdf".to_string(), "/docs/".to_string(),
        Space::Core, "application/pdf".to_string(), b"PDF1",
    ).await?;

    service.add_file(
        "doc2.pdf".to_string(), "/docs/".to_string(),
        Space::Core, "application/pdf".to_string(), b"PDF2",
    ).await?;

    service.add_file(
        "img1.jpg".to_string(), "/images/".to_string(),
        Space::Core, "image/jpeg".to_string(), b"JPG",
    ).await?;

    // List all
    let all = service.list_files(&Space::Core).await?;
    assert_eq!(all.len(), 3);

    // List PDFs only
    let pdfs = service.store.list(
        &Space::Core,
        Some("complete"),
        Some("application/pdf"),
        1000,
    ).await?;
    assert_eq!(pdfs.len(), 2);

    Ok(())
}
```

## Integration Testing

### Verify Lance Tables

```bash
# Check local Lance database
cd /var/przma/vaults/did_web_alice_com/files/

# Should see directories
ls -la
# Output:
# core/files/
# commons/files/
# sync/sync_queue/

# Inside Lance table
ls -la core/files/
# Output:
# _latest_manifest
# data/0.lance
# data/1.lance (if multiple batches)
```

### Verify CAS Blobs

```bash
# Check CAS storage
cd /var/przma/vaults/did_web_alice_com/cas/

# Should see shard directories (00-ff)
ls -la | head -20
# Output:
# 00/ 01/ 02/ ... ff/

# Inside shard
ls -la 75/
# Output:
# fd760abc1234567890abcdef...
# fd760abc1234567890abcdef....meta.json

# View metadata
cat 75/fd760abc.../fd760abc....meta.json | jq
# Output:
# {
#   "hash": "75fd760abc...",
#   "size_bytes": 5242880,
#   "mime_type": "image/jpeg",
#   "created_at": 1743868234000000,
#   "created_by": "files",
#   "ref_count": 2,
#   "is_encrypted": true
# }
```

## CLI Testing

Create `examples/file_cli.rs`:

```rust
use przma_files::FilesService;
use std::path::PathBuf;

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    let base_path = "/var/przma/vaults";
    let did = "did:web:alice.com";

    println!("Initializing FilesService...");
    let service = FilesService::new(base_path, did).await?;

    println!("\n1. Adding file to Core space...");
    let file = service.add_file(
        "example.txt".to_string(),
        "/examples/".to_string(),
        przma_files::Space::Core,
        "text/plain".to_string(),
        b"Hello from CLI!",
    ).await?;
    println!("✓ Created: {} ({})", file.id, file.content_cas);

    println!("\n2. Retrieving file...");
    let (record, bytes) = service.get_file(&file.id, &przma_files::Space::Core).await?;
    println!("✓ Retrieved: {} bytes", bytes.len());
    println!("  Content: {}", String::from_utf8_lossy(&bytes));

    println!("\n3. Listing files...");
    let files = service.list_files(&przma_files::Space::Core).await?;
    println!("✓ Found {} files", files.len());
    for f in files {
        println!("  - {} ({} bytes)", f.name, f.size_bytes);
    }

    println!("\n4. Checking sync queue...");
    let pending = service.store.pending_syncs().await?;
    println!("✓ Pending uploads: {}", pending.len());

    println!("\n✅ All operations successful!");
    Ok(())
}
```

Run:
```bash
cd przma-vault/przma-files
cargo run --example file_cli -- /var/przma/vaults did:web:alice.com
```

## Benchmarking

```rust
#[tokio::test]
async fn bench_write_100_files() -> Result<(), Box<dyn std::error::Error>> {
    let temp = tempfile::tempdir()?;
    let service = FilesService::new(
        temp.path().to_str().unwrap(),
        "did:bench:test.com"
    ).await?;

    let start = std::time::Instant::now();
    for i in 0..100 {
        service.add_file(
            format!("file_{}.txt", i),
            "/bench/".to_string(),
            Space::Core,
            "text/plain".to_string(),
            format!("Content {}", i).as_bytes(),
        ).await?;
    }
    let elapsed = start.elapsed();

    println!("Wrote 100 files in {:?}", elapsed);
    println!("Rate: {:.1} files/sec", 100.0 / elapsed.as_secs_f64());
    
    Ok(())
}
```

## Debugging

Enable logging:
```rust
// In tests
tracing_subscriber::fmt::init();

// Or set environment
RUST_LOG=debug cargo test
```

Check Lance version:
```rust
println!("Lance: {:?}", lancedb::__internal_unstable_private_version());
```

Verify Arrow schema:
```rust
let schema = przma_files::schema::file_schema();
println!("Schema fields: {}", schema.fields().len());
for field in schema.fields() {
    println!("  - {}: {}", field.name(), field.data_type());
}
```

## Checklist

- [ ] Unit tests pass: `cargo test`
- [ ] No compiler warnings: `cargo build --release`
- [ ] Clippy passes: `cargo clippy`
- [ ] Format correct: `cargo fmt`
- [ ] Documentation complete: `cargo doc --open`
- [ ] CAS blobs created correctly
- [ ] Lance tables created correctly
- [ ] Sync queue functional
- [ ] Three spaces working
- [ ] Deduplication working
- [ ] Error handling correct

## Ready for Integration! ✅
