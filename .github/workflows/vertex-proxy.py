#!/usr/bin/env python3
"""Local HTTP/1.1 bridge from Google GenAI SDK (agy CLI) to Vertex AI Publisher Models.

Enforces strict two-model policy:
  - Primary models: gemini-4-argon, gemini-3.8-flash (with optional -low/-medium/-high suffix)
  - Internal agy lightweight helper calls (*flash-lite*): rewritten to gemini-3.8-flash (LOW)
  - Any other model: rejected locally with HTTP 400 (never billed or routed to Vertex)
"""

import argparse
import http.server
import json
import os
import re
import sys
import threading
import time
import urllib.error
import urllib.request

ALLOWED_PRIMARY_MODELS = frozenset({"gemini-4-argon", "gemini-3.8-flash"})
PATH_RE = re.compile(r"^(?P<prefix>/dryrun)?/v1(?:beta1?)?/models/([^/:?]+):([^?]+)(?:\?(.*))?$")
PROJ_ERR_RE = re.compile(r"projects/([^/`\"'\s]+)/locations/")
EFFORT_SUFFIX_RE = re.compile(r"^(.+)-(low|medium|high)$")


def _parse_backoff() -> tuple[float, ...]:
    raw = os.environ.get("VERTEX_BACKOFF_SECS", "3,7,15").strip()
    vals = []
    for part in raw.split(","):
        part = part.strip()
        if part:
            vals.append(float(part))
    return tuple(vals) if vals else (3.0, 7.0, 15.0)


class BridgeState:
    def __init__(self, api_key: str, explicit_project: str, explicit_location: str):
        self.api_key = api_key
        self.explicit_project = explicit_project.strip()
        self.explicit_location = explicit_location.strip() or "global"
        self.upstream_override = os.environ.get("VERTEX_UPSTREAM_BASE_URL", "").strip().rstrip("/")
        self.backoff_secs = _parse_backoff()
        self.socket_timeout = float(os.environ.get("VERTEX_SOCKET_TIMEOUT_SECS", "240"))
        self.lock = threading.Lock()
        self.discovered_project = ""
        self.stats = {
            "requests_by_model": {},
            "helper_rewrites": 0,
            "rejected_models": {},
            "client_disconnects": 0,
            "upstream_errors": 0,
            "dryrun_requests": 0,
        }

    def inc_model(self, model: str) -> None:
        with self.lock:
            counts = self.stats["requests_by_model"]
            counts[model] = counts.get(model, 0) + 1

    def inc_rejected(self, raw_model: str) -> None:
        with self.lock:
            rej = self.stats["rejected_models"]
            rej[raw_model] = rej.get(raw_model, 0) + 1

    def inc_counter(self, key: str) -> None:
        with self.lock:
            self.stats[key] = self.stats.get(key, 0) + 1

    def snapshot(self) -> dict:
        with self.lock:
            return {
                "ok": True,
                "allowed_models": sorted(ALLOWED_PRIMARY_MODELS),
                "project": self.explicit_project or self.discovered_project,
                "location": self.explicit_location if self.explicit_project else "global",
                "stats": json.loads(json.dumps(self.stats)),
            }


def resolve_and_validate_model(raw_model: str) -> tuple[str | None, str, bool]:
    """Return (resolved_vertex_model, forced_thinking_level, was_helper_rewrite).

    Returns (None, "", False) if the requested model violates the strict 2-model policy.
    """
    forced_level = ""
    em = EFFORT_SUFFIX_RE.match(raw_model)
    if em:
        base_model = em.group(1)
        forced_level = em.group(2).upper()
    else:
        base_model = raw_model

    if base_model in ALLOWED_PRIMARY_MODELS:
        return base_model, forced_level, False

    # agy CLI internally dispatches background helper requests (e.g. summarization)
    # to gemini-3.1-flash-lite-preview, which does not exist on Vertex Publisher Models.
    if "flash-lite" in base_model:
        return "gemini-3.8-flash", "LOW", True

    return None, "", False


def build_vertex_url(
    model: str,
    action: str,
    query: str,
    project: str,
    location: str,
    upstream_override: str = "",
) -> str:
    if upstream_override:
        base = upstream_override
    elif project and location and location != "global":
        base = f"https://{location}-aiplatform.googleapis.com"
    else:
        base = "https://aiplatform.googleapis.com"

    if project:
        loc = location or "global"
        path = f"/v1beta1/projects/{project}/locations/{loc}/publishers/google/models/{model}:{action}"
    else:
        path = f"/v1beta1/publishers/google/models/{model}:{action}"

    return f"{base}{path}?{query}" if query else f"{base}{path}"


def sanitize_payload_for_model(
    model: str, action: str, raw_body: bytes, forced_level: str = ""
) -> bytes:
    if action not in ("generateContent", "streamGenerateContent"):
        return raw_body
    try:
        payload = json.loads(raw_body)
    except Exception:
        return raw_body
    if not isinstance(payload, dict):
        return raw_body

    changed = False
    is_gemini4 = model.startswith("gemini-4")

    if is_gemini4:
        for k in ("cachedContent", "cached_content"):
            if k in payload:
                payload.pop(k, None)
                changed = True

    gen_cfg = payload.get("generationConfig")
    if forced_level and not isinstance(gen_cfg, dict):
        gen_cfg = {}
        payload["generationConfig"] = gen_cfg
        changed = True

    if isinstance(gen_cfg, dict):
        if is_gemini4:
            for k in (
                "temperature",
                "topP",
                "topK",
                "top_p",
                "top_k",
                "frequencyPenalty",
                "presencePenalty",
                "frequency_penalty",
                "presence_penalty",
            ):
                if k in gen_cfg:
                    gen_cfg.pop(k, None)
                    changed = True
            for ck in ("candidateCount", "candidate_count"):
                if ck in gen_cfg and isinstance(gen_cfg[ck], int) and gen_cfg[ck] > 1:
                    gen_cfg[ck] = 1
                    changed = True

        think_cfg = gen_cfg.get("thinkingConfig")
        if forced_level and not isinstance(think_cfg, dict):
            think_cfg = {"thinkingLevel": forced_level}
            gen_cfg["thinkingConfig"] = think_cfg
            changed = True
        elif isinstance(think_cfg, dict):
            has_budget = "thinkingBudget" in think_cfg or "thinking_budget" in think_cfg
            if is_gemini4 and has_budget:
                b1 = think_cfg.pop("thinkingBudget", None)
                b2 = think_cfg.pop("thinking_budget", None)
                budget = b1 if isinstance(b1, int) else (b2 if isinstance(b2, int) else -1)
                if "thinkingLevel" not in think_cfg and "thinking_level" not in think_cfg:
                    think_cfg["thinkingLevel"] = forced_level or (
                        "HIGH" if (budget < 0 or budget >= 4096) else "MEDIUM"
                    )
                changed = True
            if forced_level:
                think_cfg.pop("thinking_level", None)
                if think_cfg.get("thinkingLevel") != forced_level:
                    think_cfg["thinkingLevel"] = forced_level
                    changed = True
            if is_gemini4:
                for lk in ("thinkingLevel", "thinking_level"):
                    if think_cfg.get(lk) == "MINIMAL":
                        think_cfg[lk] = "LOW"
                        changed = True

    return json.dumps(payload).encode("utf-8") if changed else raw_body


def strip_legacy_thinking_budget(raw_body: bytes) -> bytes | None:
    try:
        payload = json.loads(raw_body)
    except Exception:
        return None
    if not isinstance(payload, dict):
        return None
    gen_cfg = payload.get("generationConfig")
    if not isinstance(gen_cfg, dict):
        return None
    think_cfg = gen_cfg.get("thinkingConfig")
    if not isinstance(think_cfg, dict) or (
        "thinkingBudget" not in think_cfg and "thinking_budget" not in think_cfg
    ):
        return None
    b1 = think_cfg.pop("thinkingBudget", None)
    b2 = think_cfg.pop("thinking_budget", None)
    budget = b1 if isinstance(b1, int) else (b2 if isinstance(b2, int) else -1)
    if "thinkingLevel" not in think_cfg and "thinking_level" not in think_cfg:
        think_cfg["thinkingLevel"] = "HIGH" if (budget < 0 or budget >= 4096) else "LOW"
    return json.dumps(payload).encode("utf-8")


def make_handler(state: BridgeState):
    class VertexBridgeHandler(http.server.BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"

        def log_message(self, fmt, *args):
            pass

        def _safe_send_json(self, code: int, body: bytes, content_type: str = "application/json") -> None:
            try:
                self.send_response(code)
                self.send_header("Content-Type", content_type)
                self.send_header("Content-Length", str(len(body)))
                self.close_connection = True
                self.end_headers()
                self.wfile.write(body)
                self.wfile.flush()
            except (BrokenPipeError, ConnectionResetError, ConnectionAbortedError):
                state.inc_counter("client_disconnects")

        def do_GET(self):
            if self.path == "/healthz":
                body = json.dumps(state.snapshot()).encode("utf-8")
                self._safe_send_json(200, body)
                return
            msg = json.dumps({"error": {"code": 404, "message": f"Unsupported GET path: {self.path}"}}).encode("utf-8")
            self._safe_send_json(404, msg)

        def do_POST(self):
            m = PATH_RE.match(self.path)
            if not m:
                msg = json.dumps({"error": {"code": 404, "message": f"Unsupported path: {self.path}"}}).encode("utf-8")
                self._safe_send_json(404, msg)
                return

            is_dryrun = bool(m.group("prefix"))
            raw_model, action, query = m.group(2), m.group(3), m.group(4) or ""
            length = int(self.headers.get("Content-Length", 0))
            raw_body = self.rfile.read(length) if length > 0 else b""

            model, forced_level, is_helper = resolve_and_validate_model(raw_model)
            if model is None:
                state.inc_rejected(raw_model)
                err_msg = (
                    f"Model '{raw_model}' is disallowed by strict policy; "
                    f"only {', '.join(sorted(ALLOWED_PRIMARY_MODELS))} are permitted."
                )
                sys.stderr.write(f"[vertex_proxy] REJECTED model '{raw_model}': {err_msg}\n")
                sys.stderr.flush()
                msg = json.dumps({"error": {"code": 400, "message": err_msg}}).encode("utf-8")
                self._safe_send_json(400, msg)
                return

            if is_helper:
                state.inc_counter("helper_rewrites")
            state.inc_model(model)
            body = sanitize_payload_for_model(model, action, raw_body, forced_level)

            if is_dryrun:
                state.inc_counter("dryrun_requests")
                candidate_obj = {
                    "candidates": [
                        {
                            "content": {"role": "model", "parts": [{"text": "OK"}]},
                            "finishReason": "STOP",
                        }
                    ],
                    "modelVersion": model,
                }
                accept = self.headers.get("Accept", "")
                if action == "streamGenerateContent" and ("alt=sse" in query or "text/event-stream" in accept):
                    sse_payload = f"data: {json.dumps(candidate_obj)}\n\n".encode("utf-8")
                    self._safe_send_json(200, sse_payload, content_type="text/event-stream")
                elif action == "streamGenerateContent":
                    arr_payload = json.dumps([candidate_obj]).encode("utf-8")
                    self._safe_send_json(200, arr_payload)
                else:
                    self._safe_send_json(200, json.dumps(candidate_obj).encode("utf-8"))
                return

            with state.lock:
                project = state.explicit_project or state.discovered_project
            location = state.explicit_location if state.explicit_project else "global"

            headers = {
                "Content-Type": self.headers.get("Content-Type", "application/json"),
                "x-goog-api-key": state.api_key,
            }
            if "Accept" in self.headers:
                headers["Accept"] = self.headers["Accept"]

            retry_idx = 0
            timeout_retried = False
            for _attempt in range(7):
                url = build_vertex_url(
                    model, action, query, project, location, state.upstream_override
                )
                req = urllib.request.Request(url, data=body, headers=headers, method="POST")
                t0 = time.monotonic()
                try:
                    resp = urllib.request.urlopen(req, timeout=state.socket_timeout)
                except urllib.error.HTTPError as e:
                    err_body = e.read()
                    err_text = err_body.decode("utf-8", "replace")
                    if state.api_key:
                        err_text = err_text.replace(state.api_key, "***")
                    if e.code == 404 and not project:
                        pm = PROJ_ERR_RE.search(err_text)
                        if pm:
                            project = pm.group(1)
                            location = "global"
                            with state.lock:
                                state.discovered_project = project
                            continue
                    if e.code == 400 and ("thinking_budget" in err_text or "thinkingBudget" in err_text):
                        patched = strip_legacy_thinking_budget(body)
                        if patched is not None:
                            body = patched
                            continue
                    if e.code in (429, 500, 502, 503, 504) and retry_idx < len(state.backoff_secs):
                        wait_s = state.backoff_secs[retry_idx]
                        retry_idx += 1
                        sys.stderr.write(
                            f"[vertex_proxy] HTTP {e.code} on {model}:{action}; sleeping {wait_s}s before retry {retry_idx}...\n"
                        )
                        sys.stderr.flush()
                        time.sleep(wait_s)
                        continue
                    state.inc_counter("upstream_errors")
                    one_line = " ".join(err_text.split())[:220]
                    sys.stderr.write(f"[vertex_proxy] HTTP {e.code} on {model}:{action}: {one_line}\n")
                    sys.stderr.flush()
                    self._safe_send_json(e.code, err_body)
                    return
                except TimeoutError as e:
                    if not timeout_retried:
                        timeout_retried = True
                        sys.stderr.write(
                            f"[vertex_proxy] Socket timeout on {model}:{action}; retrying once...\n"
                        )
                        sys.stderr.flush()
                        continue
                    state.inc_counter("upstream_errors")
                    msg = json.dumps({"error": {"code": 504, "message": f"Vertex proxy timeout: {e}"}}).encode("utf-8")
                    self._safe_send_json(504, msg)
                    return
                except Exception as e:
                    if retry_idx < len(state.backoff_secs):
                        wait_s = state.backoff_secs[retry_idx]
                        retry_idx += 1
                        time.sleep(wait_s)
                        continue
                    state.inc_counter("upstream_errors")
                    msg = json.dumps({"error": {"code": 502, "message": f"Vertex proxy upstream error: {e}"}}).encode("utf-8")
                    self._safe_send_json(502, msg)
                    return

                # Upstream responded; stream back to local client. Never retry upstream if local client disconnects!
                with resp:
                    ttfb = time.monotonic() - t0
                    tag = f"{model}(<-{raw_model})" if is_helper else model
                    sys.stderr.write(
                        f"[vertex_proxy] {tag}:{action} -> HTTP {resp.status} (ttfb {ttfb:.1f}s)\n"
                    )
                    sys.stderr.flush()
                    try:
                        self.send_response(resp.status)
                        ctype = resp.headers.get("Content-Type", "application/json")
                        self.send_header("Content-Type", ctype)
                        self.close_connection = True
                        self.end_headers()
                        while True:
                            chunk = resp.read1(4096) if hasattr(resp, "read1") else resp.read(4096)
                            if not chunk:
                                break
                            self.wfile.write(chunk)
                            self.wfile.flush()
                    except (BrokenPipeError, ConnectionResetError, ConnectionAbortedError):
                        state.inc_counter("client_disconnects")
                        sys.stderr.write(
                            f"[vertex_proxy] Client disconnected while streaming {tag}:{action}; closing cleanly without retry.\n"
                        )
                        sys.stderr.flush()
                    return

    return VertexBridgeHandler


def probe_live_vertex(state: BridgeState, models: list[str]) -> int:
    """Send minimal generateContent ping to Vertex AI for each target model."""
    for raw_model in models:
        model, forced_level, _ = resolve_and_validate_model(raw_model)
        if model is None:
            sys.stderr.write(f"[probe] Model '{raw_model}' disallowed by policy.\n")
            return 1

        raw_payload = json.dumps(
            {
                "contents": [{"role": "user", "parts": [{"text": "Reply with OK"}]}],
                "generationConfig": {
                    "maxOutputTokens": 16,
                    "thinkingConfig": {"thinkingLevel": forced_level or "LOW"},
                },
            }
        ).encode("utf-8")
        body = sanitize_payload_for_model(model, "generateContent", raw_payload, forced_level or "LOW")

        with state.lock:
            project = state.explicit_project or state.discovered_project
        location = state.explicit_location if state.explicit_project else "global"

        headers = {
            "Content-Type": "application/json",
            "x-goog-api-key": state.api_key,
        }

        retry_idx = 0
        ok = False
        for _attempt in range(5):
            url = build_vertex_url(
                model, "generateContent", "", project, location, state.upstream_override
            )
            req = urllib.request.Request(url, data=body, headers=headers, method="POST")
            t0 = time.monotonic()
            try:
                with urllib.request.urlopen(req, timeout=60) as resp:
                    resp_bytes = resp.read()
                    elapsed = time.monotonic() - t0
                    parsed = json.loads(resp_bytes.decode("utf-8", "replace"))
                    if not isinstance(parsed, dict) or "candidates" not in parsed:
                        sys.stderr.write(
                            f"[probe] Unexpected response payload for {model}: {resp_bytes[:200]!r}\n"
                        )
                        return 1
                    print(
                        f"[probe] OK {model} (HTTP {resp.status}, {elapsed:.2f}s, project={project or 'publisher'})"
                    )
                    ok = True
                    break
            except urllib.error.HTTPError as e:
                err_text = e.read().decode("utf-8", "replace")
                if state.api_key:
                    err_text = err_text.replace(state.api_key, "***")
                if e.code == 404 and not project:
                    pm = PROJ_ERR_RE.search(err_text)
                    if pm:
                        project = pm.group(1)
                        location = "global"
                        with state.lock:
                            state.discovered_project = project
                        continue
                if e.code in (429, 500, 502, 503, 504) and retry_idx < len(state.backoff_secs):
                    wait_s = state.backoff_secs[retry_idx]
                    retry_idx += 1
                    time.sleep(wait_s)
                    continue
                sys.stderr.write(
                    f"[probe] FAILED {model}: HTTP {e.code}: {' '.join(err_text.split())[:240]}\n"
                )
                return 1
            except Exception as e:
                sys.stderr.write(f"[probe] ERROR {model}: {e}\n")
                return 1

        if not ok:
            sys.stderr.write(f"[probe] Exhausted retries for {model}\n")
            return 1
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description="Vertex AI strict 2-model local bridge")
    parser.add_argument("port_file", nargs="?", help="Path to atomically write bound TCP port")
    parser.add_argument(
        "--probe-vertex",
        action="store_true",
        help="Verify live Vertex AI access for gemini-4-argon and gemini-3.8-flash and exit",
    )
    parser.add_argument(
        "--models",
        default="gemini-4-argon,gemini-3.8-flash",
        help="Comma-separated models for --probe-vertex",
    )
    args = parser.parse_args()

    api_key = os.environ.get("VERTEX_API_KEY", "").strip()
    if not api_key:
        sys.stderr.write("[vertex_proxy] VERTEX_API_KEY environment variable is empty.\n")
        return 1

    state = BridgeState(
        api_key=api_key,
        explicit_project=os.environ.get("VERTEX_PROJECT_ID", ""),
        explicit_location=os.environ.get("VERTEX_LOCATION", ""),
    )

    if args.probe_vertex:
        target_models = [m.strip() for m in args.models.split(",") if m.strip()]
        return probe_live_vertex(state, target_models)

    if not args.port_file:
        sys.stderr.write("[vertex_proxy] port_file is required when running server mode.\n")
        return 2

    srv = http.server.ThreadingHTTPServer(("127.0.0.1", 0), make_handler(state))
    srv.daemon_threads = True
    tmp_file = f"{args.port_file}.tmp"
    with open(tmp_file, "w", encoding="utf-8") as fh:
        fh.write(str(srv.server_address[1]))
    os.replace(tmp_file, args.port_file)
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        srv.server_close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
