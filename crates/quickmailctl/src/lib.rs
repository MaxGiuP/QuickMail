//! Small, script-friendly JSON-RPC client for `quickmaild`.

use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};

use anyhow::{Context, Result, anyhow, bail};
use serde_json::{Value, json};
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::net::UnixStream;

static NEXT_ID: AtomicU64 = AtomicU64::new(1);

pub fn resolve_socket(override_path: Option<PathBuf>) -> Result<PathBuf> {
    if let Some(path) = override_path {
        return Ok(path);
    }
    let runtime = std::env::var_os("XDG_RUNTIME_DIR")
        .map(PathBuf::from)
        .ok_or_else(|| anyhow!("XDG_RUNTIME_DIR is unset; pass --socket explicitly"))?;
    Ok(runtime.join("quickmail/daemon.sock"))
}

pub async fn call(socket: &Path, method: &str, params: Value) -> Result<Value> {
    let id = NEXT_ID.fetch_add(1, Ordering::Relaxed);
    let request = json!({
        "jsonrpc": "2.0",
        "id": id,
        "method": method,
        "params": params,
    });
    let stream = UnixStream::connect(socket)
        .await
        .with_context(|| format!("cannot connect to {}", socket.display()))?;
    let (reader, mut writer) = stream.into_split();
    let mut encoded = serde_json::to_vec(&request)?;
    encoded.push(b'\n');
    writer.write_all(&encoded).await?;
    writer.flush().await?;

    let mut lines = BufReader::new(reader).lines();
    while let Some(line) = lines.next_line().await? {
        let message: Value = serde_json::from_str(&line).context("daemon returned invalid JSON")?;
        if message.get("id") != Some(&Value::from(id)) {
            continue;
        }
        if let Some(error) = message.get("error") {
            let code = error.get("code").and_then(Value::as_i64).unwrap_or(-1);
            let text = error
                .get("message")
                .and_then(Value::as_str)
                .unwrap_or("unknown RPC error");
            bail!("RPC error {code}: {text}");
        }
        return message
            .get("result")
            .cloned()
            .ok_or_else(|| anyhow!("daemon response has neither result nor error"));
    }
    bail!("daemon closed the socket before replying")
}

pub async fn watch(socket: &Path, topics: Vec<String>) -> Result<()> {
    let id = NEXT_ID.fetch_add(1, Ordering::Relaxed);
    let request = json!({
        "jsonrpc": "2.0",
        "id": id,
        "method": "subscribe",
        "params": { "topics": topics },
    });
    let stream = UnixStream::connect(socket)
        .await
        .with_context(|| format!("cannot connect to {}", socket.display()))?;
    let (reader, mut writer) = stream.into_split();
    let mut encoded = serde_json::to_vec(&request)?;
    encoded.push(b'\n');
    writer.write_all(&encoded).await?;
    writer.flush().await?;

    let mut lines = BufReader::new(reader).lines();
    while let Some(line) = lines.next_line().await? {
        let value: Value = serde_json::from_str(&line).context("daemon returned invalid JSON")?;
        println!("{}", serde_json::to_string(&value)?);
    }
    Ok(())
}

pub fn print_json(value: &Value, compact: bool) -> Result<()> {
    if compact {
        println!("{}", serde_json::to_string(value)?);
    } else {
        println!("{}", serde_json::to_string_pretty(value)?);
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use tempfile::tempdir;
    use tokio::net::UnixListener;

    #[tokio::test]
    async fn call_sends_json_rpc_and_returns_result() {
        let directory = tempdir().unwrap();
        let socket = directory.path().join("daemon.sock");
        let listener = UnixListener::bind(&socket).unwrap();
        let server = tokio::spawn(async move {
            let (stream, _) = listener.accept().await.unwrap();
            let (reader, mut writer) = stream.into_split();
            let mut lines = BufReader::new(reader).lines();
            let line = lines.next_line().await.unwrap().unwrap();
            let request: Value = serde_json::from_str(&line).unwrap();
            assert_eq!(request["jsonrpc"], "2.0");
            assert_eq!(request["method"], "ping");
            assert_eq!(request["params"]["probe"], true);
            let response = json!({
                "jsonrpc": "2.0",
                "id": request["id"],
                "result": { "status": "ok" },
            });
            writer
                .write_all(format!("{response}\n").as_bytes())
                .await
                .unwrap();
        });

        let result = call(&socket, "ping", json!({ "probe": true }))
            .await
            .unwrap();
        assert_eq!(result["status"], "ok");
        server.await.unwrap();
    }

    #[test]
    fn explicit_socket_wins() {
        let expected = PathBuf::from("/tmp/quickmail-test.sock");
        assert_eq!(resolve_socket(Some(expected.clone())).unwrap(), expected);
    }
}
