// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Cua AI, Inc.

//! Cross-platform CDP (Chrome DevTools Protocol) helper.
//!
//! Legacy-compatible `Runtime.evaluate` support for the cross-platform
//! `page` tool. HTTP target discovery and first-page/URL-hint selection retain
//! the published legacy behavior, while WebSocket calls use the same pooled,
//! event-aware [`crate::browser::cdp_ws::CdpConnection`] transport as the
//! first-class browser tools.
//!
//! Flow:
//!  1. HTTP GET http://127.0.0.1:{cdp_port}/json  → discover page WS URLs.
//!  2. Reuse or connect the selected page WebSocket through `CdpPool`.
//!  3. Send Runtime.evaluate with userGesture=true.
//!  4. Let the shared demultiplexer match the response without losing events.

use serde_json::Value;
use std::sync::OnceLock;

use crate::browser::cdp_ws::CdpPool;

fn legacy_pool() -> &'static CdpPool {
    static POOL: OnceLock<CdpPool> = OnceLock::new();
    POOL.get_or_init(CdpPool::new)
}

/// Evaluate `expression` in the first page tab exposed by a Chromium-family
/// browser listening on `port` (the value passed to `--remote-debugging-port`).
///
/// Returns the formatted result (or `exception: ...` if the evaluated code
/// raised). Caller is responsible for prefixing the human-readable label
/// (e.g. `"cdp.runtime.evaluate.user_gesture: ..."`).
pub async fn evaluate(port: u16, expression: &str, await_promise: bool) -> anyhow::Result<String> {
    evaluate_targeted(port, expression, await_promise, None).await
}

/// Evaluate `expression` in the unique page whose URL contains
/// `target_url_contains`. When no hint is supplied, preserves the legacy
/// first-page behavior.
pub async fn evaluate_targeted(
    port: u16,
    expression: &str,
    await_promise: bool,
    target_url_contains: Option<&str>,
) -> anyhow::Result<String> {
    let response = cdp_evaluate(port, expression, await_promise, target_url_contains).await?;
    Ok(format_cdp_result(&response))
}

// ── High-level evaluate ───────────────────────────────────────────────────

async fn cdp_evaluate(
    port: u16,
    expression: &str,
    await_promise: bool,
    target_url_contains: Option<&str>,
) -> anyhow::Result<Value> {
    // A listener can be reachable before Chromium publishes its first page
    // target. Bound both that readiness interval and the HTTP roundtrip.
    let pages = tokio::time::timeout(std::time::Duration::from_secs(10), cdp_wait_for_page(port))
        .await
        .map_err(|_| {
            anyhow::anyhow!("CDP /json discovery on port {port} timed out after 10 s")
        })??;

    let page = pick_page(&pages, target_url_contains).ok_or_else(|| match target_url_contains {
        Some(hint) => anyhow::anyhow!("No unique CDP page URL contains {hint:?} on port {port}"),
        None => anyhow::anyhow!("No CDP page tabs found on port {port}"),
    })?;
    let ws_url = page
        .get("webSocketDebuggerUrl")
        .and_then(|u| u.as_str())
        .ok_or_else(|| anyhow::anyhow!("Page has no webSocketDebuggerUrl"))?
        .to_string();

    let connection = legacy_pool().get(&ws_url).await?;
    let result = tokio::time::timeout(
        std::time::Duration::from_secs(30),
        connection.call(
            None,
            "Runtime.evaluate",
            serde_json::json!({
                "expression": expression,
                "userGesture": true,
                "awaitPromise": await_promise
            }),
        ),
    )
    .await
    .map_err(|_| anyhow::anyhow!("CDP evaluate timed out after 30 s"))??;
    Ok(serde_json::json!({ "result": result }))
}

/// Pick the unique page whose `url` contains `hint` (case-insensitive), or
/// the first page when no hint is given.
///
/// Explicit hints fail closed when zero or multiple pages match: CDP target
/// ids carry no relationship to the caller's window, so a browser with more
/// than one tab open would otherwise be picked non-deterministically.
pub fn pick_page<'a>(
    pages: impl IntoIterator<Item = &'a Value>,
    hint: Option<&str>,
) -> Option<&'a Value> {
    let mut pages = pages.into_iter();
    match hint {
        None => pages.next(),
        Some(hint) => {
            let hint_lower = hint.to_ascii_lowercase();
            let mut matches = pages.filter(|page| {
                page.get("url")
                    .and_then(Value::as_str)
                    .is_some_and(|url| url.to_ascii_lowercase().contains(&hint_lower))
            });
            let page = matches.next()?;
            if matches.next().is_some() {
                return None;
            }
            Some(page)
        }
    }
}

fn format_cdp_result(response: &Value) -> String {
    if let Some(exc) = response
        .get("result")
        .and_then(|r| r.get("exceptionDetails"))
    {
        let msg = exc
            .get("exception")
            .and_then(|e| e.get("description"))
            .and_then(|d| d.as_str())
            .map(str::to_owned)
            .unwrap_or_else(|| exc.to_string());
        return format!("exception: {msg}");
    }

    if let Some(result) = response.get("result").and_then(|r| r.get("result")) {
        if let Some(v) = result.get("value") {
            return v.to_string();
        }
        if let Some(desc) = result.get("description").and_then(|d| d.as_str()) {
            return desc.to_string();
        }
    }

    response.to_string()
}

/// Returns true if the CDP target URL is internal (e.g. omnibox popup, untrusted UI, or devtools).
pub fn is_internal_target_url(url: &str) -> bool {
    url.starts_with("chrome://omnibox-popup")
        || url.starts_with("chrome-untrusted://")
        || url.starts_with("devtools://")
}

// ── HTTP page discovery ───────────────────────────────────────────────────

async fn cdp_wait_for_page(port: u16) -> anyhow::Result<Vec<Value>> {
    loop {
        let pages = cdp_list_pages(port).await?;
        if !pages.is_empty() {
            return Ok(pages);
        }
        tokio::time::sleep(std::time::Duration::from_millis(100)).await;
    }
}

async fn cdp_http_get(port: u16, path: &str) -> anyhow::Result<Value> {
    use tokio::io::{AsyncBufReadExt, AsyncReadExt, AsyncWriteExt, BufReader};

    let mut stream = tokio::net::TcpStream::connect(("127.0.0.1", port))
        .await
        .map_err(|e| anyhow::anyhow!("Cannot connect to CDP on port {port}: {e}"))?;

    let req = format!("GET {path} HTTP/1.1\r\nHost: 127.0.0.1:{port}\r\nConnection: close\r\n\r\n");
    stream.write_all(req.as_bytes()).await?;

    let mut reader = BufReader::new(stream);
    let mut header_line = String::new();
    let mut content_length: Option<usize> = None;
    let mut chunked = false;
    loop {
        header_line.clear();
        let n = reader.read_line(&mut header_line).await?;
        if n == 0 {
            anyhow::bail!("CDP {path}: EOF in headers");
        }
        if header_line == "\r\n" {
            break;
        }
        let lower = header_line.to_ascii_lowercase();
        if let Some(v) = lower.strip_prefix("content-length:") {
            content_length = v.trim().parse::<usize>().ok();
        }
        if lower.starts_with("transfer-encoding:") && lower.contains("chunked") {
            chunked = true;
        }
    }

    let body_bytes: Vec<u8> = if let Some(n) = content_length {
        let mut buf = vec![0u8; n];
        reader.read_exact(&mut buf).await?;
        buf
    } else if chunked {
        let mut out = Vec::new();
        loop {
            let mut size_line = String::new();
            reader.read_line(&mut size_line).await?;
            let size = usize::from_str_radix(size_line.trim_end(), 16)
                .map_err(|_| anyhow::anyhow!("CDP {path}: bad chunk size {size_line:?}"))?;
            if size == 0 {
                break;
            }
            let mut chunk = vec![0u8; size];
            reader.read_exact(&mut chunk).await?;
            out.extend_from_slice(&chunk);
            let mut crlf = [0u8; 2];
            reader.read_exact(&mut crlf).await?;
        }
        out
    } else {
        let mut buf = Vec::new();
        reader.read_to_end(&mut buf).await?;
        buf
    };

    let body = std::str::from_utf8(&body_bytes)
        .map_err(|_| anyhow::anyhow!("CDP {path} response is not valid UTF-8"))?;

    serde_json::from_str(body).map_err(|e| anyhow::anyhow!("CDP {path} parse error: {e}"))
}

async fn cdp_list_pages(port: u16) -> anyhow::Result<Vec<Value>> {
    let all = cdp_http_get(port, "/json").await?;

    let pages = all
        .as_array()
        .ok_or_else(|| anyhow::anyhow!("CDP /json is not a JSON array"))?
        .iter()
        .filter(|p| {
            if p.get("type").and_then(|t| t.as_str()) != Some("page") {
                return false;
            }
            if p.get("webSocketDebuggerUrl")
                .and_then(|u| u.as_str())
                .is_none()
            {
                return false;
            }
            if let Some(url) = p.get("url").and_then(|u| u.as_str()) {
                if is_internal_target_url(url) {
                    return false;
                }
            }
            true
        })
        .cloned()
        .collect();

    Ok(pages)
}

/// Adjust Chromium window geometry via CDP Browser.setWindowBounds.
/// Returns the verified (x, y, width, height) read back from Browser.getWindowBounds.
pub async fn set_window_bounds_via_cdp(
    port: u16,
    x: i32,
    y: i32,
    width: u32,
    height: u32,
) -> anyhow::Result<(i32, i32, u32, u32)> {
    let version_info = cdp_http_get(port, "/json/version").await?;
    let browser_ws_url = version_info
        .get("webSocketDebuggerUrl")
        .and_then(Value::as_str)
        .ok_or_else(|| {
            anyhow::anyhow!("CDP /json/version has no webSocketDebuggerUrl on port {port}")
        })?;

    let pages = cdp_wait_for_page(port).await?;
    let first_page = pages
        .first()
        .ok_or_else(|| anyhow::anyhow!("No active CDP pages on port {port}"))?;
    let target_id = first_page
        .get("id")
        .and_then(Value::as_str)
        .ok_or_else(|| anyhow::anyhow!("CDP page target has no id"))?;

    let conn = if let Some(live) =
        crate::browser::cdp_ws::find_live_endpoint_connection(browser_ws_url).await
    {
        live
    } else {
        match crate::browser::cdp_ws::CdpConnection::connect(browser_ws_url).await {
            Ok(c) => std::sync::Arc::new(c),
            Err(_) => legacy_pool().get(browser_ws_url).await?,
        }
    };

    let window_resp = conn
        .call(
            None,
            "Browser.getWindowForTarget",
            serde_json::json!({ "targetId": target_id }),
        )
        .await?;
    let window_id = window_resp
        .get("windowId")
        .and_then(Value::as_i64)
        .ok_or_else(|| anyhow::anyhow!("Browser.getWindowForTarget did not return windowId"))?;

    let bounds_params = serde_json::json!({
        "windowId": window_id,
        "bounds": {
            "left": x,
            "top": y,
            "width": width,
            "height": height,
            "windowState": "normal"
        }
    });
    conn.call(None, "Browser.setWindowBounds", bounds_params)
        .await?;

    let readback_resp = conn
        .call(
            None,
            "Browser.getWindowBounds",
            serde_json::json!({ "windowId": window_id }),
        )
        .await?;
    let bounds = readback_resp
        .get("bounds")
        .ok_or_else(|| anyhow::anyhow!("Browser.getWindowBounds returned no bounds"))?;

    let actual_x = bounds
        .get("left")
        .and_then(Value::as_i64)
        .unwrap_or(x as i64) as i32;
    let actual_y = bounds
        .get("top")
        .and_then(Value::as_i64)
        .unwrap_or(y as i64) as i32;
    let actual_w = bounds
        .get("width")
        .and_then(Value::as_u64)
        .unwrap_or(width as u64) as u32;
    let actual_h = bounds
        .get("height")
        .and_then(Value::as_u64)
        .unwrap_or(height as u64) as u32;

    Ok((actual_x, actual_y, actual_w, actual_h))
}

#[cfg(test)]
mod tests {
    use super::{evaluate, format_cdp_result, pick_page};
    use futures_util::{SinkExt, StreamExt};
    use serde_json::json;
    use tokio::io::{AsyncReadExt, AsyncWriteExt};
    use tokio_tungstenite::{accept_async, tungstenite::Message};

    fn pages() -> Vec<serde_json::Value> {
        vec![
            json!({ "url": "app://fixture/#window-a", "webSocketDebuggerUrl": "ws://a" }),
            json!({ "url": "app://fixture/#window-b", "webSocketDebuggerUrl": "ws://b" }),
        ]
    }

    #[test]
    fn targeted_page_selection_is_unique_and_case_insensitive() {
        let pages = pages();
        assert_eq!(
            pick_page(&pages, Some("#WINDOW-B"))
                .and_then(|page| page["webSocketDebuggerUrl"].as_str()),
            Some("ws://b")
        );
        assert!(pick_page(&pages, Some("#missing")).is_none());
        assert!(pick_page(&pages, Some("app://fixture/")).is_none());
    }

    #[test]
    fn omitted_page_hint_preserves_first_page_behavior() {
        let pages = pages();
        assert_eq!(
            pick_page(&pages, None).and_then(|page| page["webSocketDebuggerUrl"].as_str()),
            Some("ws://a")
        );
    }

    #[test]
    fn legacy_result_format_is_unchanged() {
        assert_eq!(
            format_cdp_result(&json!({ "result": { "result": { "value": "text" } } })),
            "\"text\""
        );
        assert_eq!(
            format_cdp_result(&json!({
                "result": {
                    "exceptionDetails": {
                        "exception": { "description": "ReferenceError: missing" }
                    }
                }
            })),
            "exception: ReferenceError: missing"
        );
    }

    #[tokio::test]
    async fn evaluate_uses_event_aware_transport_without_changing_output() {
        let listener = tokio::net::TcpListener::bind(("127.0.0.1", 0))
            .await
            .unwrap();
        let port = listener.local_addr().unwrap().port();
        let server = tokio::spawn(async move {
            let (mut http, _) = listener.accept().await.unwrap();
            let mut request = [0u8; 1024];
            let _ = http.read(&mut request).await.unwrap();
            let body = json!([{
                "type": "page",
                "url": "app://fixture/",
                "webSocketDebuggerUrl": format!("ws://127.0.0.1:{port}/devtools/page/compat")
            }])
            .to_string();
            http.write_all(
                format!(
                    "HTTP/1.1 200 OK\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{}",
                    body.len(),
                    body
                )
                .as_bytes(),
            )
            .await
            .unwrap();

            let (socket, _) = listener.accept().await.unwrap();
            let mut websocket = accept_async(socket).await.unwrap();
            let Message::Text(text) = websocket.next().await.unwrap().unwrap() else {
                panic!("expected Runtime.evaluate request")
            };
            let call: serde_json::Value = serde_json::from_str(&text).unwrap();
            assert_eq!(call["method"], "Runtime.evaluate");
            let id = call["id"].as_u64().unwrap();
            websocket
                .send(Message::Text(
                    json!({ "method": "Runtime.consoleAPICalled", "params": {} }).to_string(),
                ))
                .await
                .unwrap();
            websocket
                .send(Message::Text(
                    json!({
                        "id": id,
                        "result": { "result": { "value": "compat" } }
                    })
                    .to_string(),
                ))
                .await
                .unwrap();
        });

        assert_eq!(evaluate(port, "1 + 1", true).await.unwrap(), "\"compat\"");
        server.await.unwrap();
    }

    #[test]
    fn internal_target_urls_are_filtered() {
        assert!(super::is_internal_target_url(
            "chrome://omnibox-popup.top-chrome/"
        ));
        assert!(super::is_internal_target_url(
            "chrome-untrusted://new-tab-page/one-google-bar"
        ));
        assert!(super::is_internal_target_url(
            "devtools://devtools/bundled/devtools_app.html"
        ));
        assert!(!super::is_internal_target_url("https://example.com"));
        assert!(!super::is_internal_target_url("chrome://newtab/"));
        assert!(!super::is_internal_target_url("about:blank"));
    }
}
