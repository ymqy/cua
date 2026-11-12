#!/usr/bin/env python3
"""Fast deterministic unit & integration tests for the fork sync infrastructure.

Covers:
  1. Strict 2-model static policy (ONLY gemini-4-argon & gemini-3.8-flash; no other fallbacks)
  2. Fork workflow self-preservation & upstream workflow pruning under Git merge conflicts
  3. vertex-proxy.py routing, Gemini 4 sanitization, flash-lite helper rewrite, 429 retry,
     /dryrun SSE/JSON responses, and zero-retry clean handling of BrokenPipeError
  4. verify-fork-driver.sh failure parser (Cargo backtick rerun spec, sticky runtime target,
     and deduplication of --all-targets compiler diagnostics)
"""

import http.server
import json
import os
import re
import shlex
import socket
import subprocess
import tempfile
import threading
import time
import unittest
import urllib.error
import urllib.request
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
WF_DIR = REPO_ROOT / ".github" / "workflows"


def parse_shell_env_file(path: Path) -> dict[str, str]:
    result: dict[str, str] = {}
    if not path.is_file():
        return result
    for line in path.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line or "=" not in line:
            continue
        k, v = line.split("=", 1)
        tokens = shlex.split(v)
        result[k] = tokens[0] if tokens else ""
    return result


class _MockVertexUpstream:
    def __init__(self):
        self.lock = threading.Lock()
        self.calls: list[dict] = []
        self.mode = "normal"
        self.rate_limit_remaining = 0
        self.stall_remaining = 0

        outer = self

        class Handler(http.server.BaseHTTPRequestHandler):
            protocol_version = "HTTP/1.1"

            def log_message(self, fmt, *args):
                pass

            def do_POST(self):
                length = int(self.headers.get("Content-Length", 0))
                raw = self.rfile.read(length) if length > 0 else b"{}"
                try:
                    body = json.loads(raw.decode("utf-8"))
                except Exception:
                    body = {}

                with outer.lock:
                    outer.calls.append(
                        {
                            "path": self.path,
                            "api_key": self.headers.get("x-goog-api-key", ""),
                            "body": body,
                        }
                    )
                    mode = outer.mode
                    rl_rem = outer.rate_limit_remaining
                    if rl_rem > 0:
                        outer.rate_limit_remaining -= 1
                    stall = outer.stall_remaining > 0 and "/projects/" in self.path
                    if stall:
                        outer.stall_remaining -= 1

                # Simulate publisher 404 when project is missing so auto-discovery is tested.
                if "/projects/" not in self.path:
                    err = {
                        "error": {
                            "code": 404,
                            "message": "Publisher model `projects/987654321/locations/global/publishers/google/models/x` not found",
                        }
                    }
                    payload = json.dumps(err).encode("utf-8")
                    self.send_response(404)
                    self.send_header("Content-Type", "application/json")
                    self.send_header("Content-Length", str(len(payload)))
                    self.end_headers()
                    self.wfile.write(payload)
                    return

                if stall:
                    time.sleep(0.35)
                    return

                if rl_rem > 0:
                    err = {"error": {"code": 429, "message": "Resource exhausted"}}
                    payload = json.dumps(err).encode("utf-8")
                    self.send_response(429)
                    self.send_header("Content-Type", "application/json")
                    self.send_header("Content-Length", str(len(payload)))
                    self.end_headers()
                    self.wfile.write(payload)
                    return

                resp_obj = {
                    "candidates": [
                        {
                            "content": {"role": "model", "parts": [{"text": "PONG"}]},
                            "finishReason": "STOP",
                        }
                    ]
                }
                payload = json.dumps(resp_obj).encode("utf-8")

                if mode == "slow_stream":
                    time.sleep(0.18)
                    try:
                        self.send_response(200)
                        self.send_header("Content-Type", "application/json")
                        self.end_headers()
                        for _ in range(8):
                            self.wfile.write(payload)
                            self.wfile.flush()
                            time.sleep(0.03)
                    except (BrokenPipeError, ConnectionResetError, ConnectionAbortedError):
                        pass
                    return

                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(payload)))
                self.end_headers()
                self.wfile.write(payload)

        self.server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.server.daemon_threads = True
        self.port = self.server.server_address[1]
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()

    def close(self):
        self.server.shutdown()
        self.server.server_close()


class SyncInfraTests(unittest.TestCase):
    def test_strict_two_model_static_policy(self):
        forbidden = re.compile(
            r"gemini-4-carbon|gemini-3\.[0-7]|gemini-2\.|claude-|gpt-4",
            re.IGNORECASE,
        )
        checked_files = [
            WF_DIR / "sync-upstream.yml",
            WF_DIR / "verify-sync-infra.yml",
            WF_DIR / "agy-sync-lib.sh",
            WF_DIR / "vertex-proxy.py",
        ]
        for path in checked_files:
            self.assertTrue(path.is_file(), f"Missing expected workflow file: {path}")
            content = path.read_text(encoding="utf-8")
            # Strip comment lines before scanning so explanatory docstrings don't false-positive.
            code_lines = [
                ln for ln in content.splitlines() if not ln.lstrip().startswith("#")
            ]
            joined = "\n".join(code_lines)
            m = forbidden.search(joined)
            self.assertIsNone(
                m,
                f"Forbidden fallback model reference '{m.group(0) if m else ''}' found in {path.name}",
            )

    def test_workflow_yaml_run_blocks_bash_syntax(self):
        yaml_mod = None
        try:
            import yaml as yaml_mod
        except ImportError:
            pass

        for wf_name in ("sync-upstream.yml", "verify-sync-infra.yml"):
            wf_path = WF_DIR / wf_name
            if yaml_mod is not None:
                doc = yaml_mod.safe_load(wf_path.read_text(encoding="utf-8"))
            else:
                try:
                    out = subprocess.check_output(
                        [
                            "ruby",
                            "-ryaml",
                            "-rjson",
                            "-e",
                            "puts JSON.generate(YAML.safe_load(File.read(ARGV[0]), permitted_classes: [Date, Time]))",
                            str(wf_path),
                        ],
                        text=True,
                    )
                except FileNotFoundError:
                    self.skipTest("Neither PyYAML nor ruby is installed")
                doc = json.loads(out)
            self.assertIsInstance(doc, dict)
            jobs = doc.get("jobs", {})
            self.assertTrue(jobs)
            for job_id, job_cfg in jobs.items():
                for idx, step in enumerate(job_cfg.get("steps", [])):
                    if "run" not in step:
                        continue
                    script = re.sub(r"\$\{\{[^}]+\}\}", "dummy_val", step["run"])
                    proc = subprocess.run(
                        ["bash", "-n"],
                        input=script,
                        text=True,
                        capture_output=True,
                    )
                    self.assertEqual(
                        proc.returncode,
                        0,
                        f"bash -n failed in {wf_name} job '{job_id}' step #{idx} ({step.get('name')}):\n{proc.stderr}",
                    )

    def test_fork_workflow_protection_and_merge_pruning(self):
        lib_path = WF_DIR / "agy-sync-lib.sh"
        actual_exec_files = sorted(
            f".github/workflows/{p.name}"
            for p in WF_DIR.iterdir()
            if p.is_file() and p.suffix in {".yml", ".yaml", ".sh", ".py"}
        )
        for rel in actual_exec_files:
            rc = subprocess.run(
                [
                    "bash",
                    "-c",
                    f'source {shlex.quote(str(lib_path))} && is_protected_fork_workflow_file {shlex.quote(rel)}',
                ],
                cwd=REPO_ROOT,
            ).returncode
            self.assertEqual(
                rc,
                0,
                f"{rel} exists in .github/workflows/ but is NOT protected in FORK_PROTECTED_WORKFLOW_FILES!",
            )

        with tempfile.TemporaryDirectory() as tmp:
            repo = Path(tmp)
            subprocess.run(["git", "init", "-b", "main"], cwd=repo, check=True, capture_output=True)
            subprocess.run(["git", "config", "user.name", "Test"], cwd=repo, check=True)
            subprocess.run(["git", "config", "user.email", "test@example.com"], cwd=repo, check=True)

            wf = repo / ".github" / "workflows"
            wf.mkdir(parents=True)
            (wf / "ci.yml").write_text("name: Upstream CI v1\n", encoding="utf-8")
            subprocess.run(["git", "add", "."], cwd=repo, check=True)
            subprocess.run(["git", "commit", "-m", "base"], cwd=repo, check=True, capture_output=True)

            # Create fork branch that deletes upstream ci.yml and adds sync-upstream.yml + verify-sync-infra.yml
            subprocess.run(["git", "checkout", "-b", "fork-branch"], cwd=repo, check=True, capture_output=True)
            subprocess.run(["git", "rm", ".github/workflows/ci.yml"], cwd=repo, check=True, capture_output=True)
            wf.mkdir(parents=True, exist_ok=True)
            (wf / "sync-upstream.yml").write_text("name: Sync\n", encoding="utf-8")
            (wf / "verify-sync-infra.yml").write_text("name: Verify Infra\n", encoding="utf-8")
            subprocess.run(["git", "add", "."], cwd=repo, check=True)
            subprocess.run(["git", "commit", "-m", "fork setup"], cwd=repo, check=True, capture_output=True)

            # Advance main with modified ci.yml (triggers UD conflict!) + brand-new release.yml
            subprocess.run(["git", "checkout", "main"], cwd=repo, check=True, capture_output=True)
            (wf / "ci.yml").write_text("name: Upstream CI v2\n", encoding="utf-8")
            (wf / "release.yml").write_text("name: Upstream Release\n", encoding="utf-8")
            subprocess.run(["git", "add", "."], cwd=repo, check=True)
            subprocess.run(["git", "commit", "-m", "upstream update"], cwd=repo, check=True, capture_output=True)

            # Merge main into fork-branch and run prune_upstream_workflows
            subprocess.run(["git", "checkout", "fork-branch"], cwd=repo, check=True, capture_output=True)
            subprocess.run(["git", "merge", "--no-commit", "--no-ff", "main"], cwd=repo, capture_output=True)
            subprocess.run(
                ["bash", "-c", f"source {shlex.quote(str(lib_path))} && prune_upstream_workflows"],
                cwd=repo,
                check=True,
            )

            unmerged = subprocess.check_output(
                ["git", "diff", "--name-only", "--diff-filter=U"], cwd=repo, text=True
            ).strip()
            self.assertEqual(unmerged, "", f"Expected zero unmerged workflow files, got: {unmerged}")
            self.assertTrue((wf / "sync-upstream.yml").is_file())
            self.assertTrue((wf / "verify-sync-infra.yml").is_file())
            self.assertFalse((wf / "ci.yml").exists())
            self.assertFalse((wf / "release.yml").exists())

    def test_write_agy_trusted_settings(self):
        lib_path = WF_DIR / "agy-sync-lib.sh"
        with tempfile.TemporaryDirectory() as tmp:
            env = os.environ.copy()
            env["HOME"] = tmp
            subprocess.run(
                [
                    "bash",
                    "-c",
                    f'source {shlex.quote(str(lib_path))} && write_agy_trusted_settings /ws/main /ws/probe',
                ],
                env=env,
                check=True,
            )
            settings_file = Path(tmp) / ".gemini" / "antigravity-cli" / "settings.json"
            data = json.loads(settings_file.read_text(encoding="utf-8"))
            self.assertEqual(data["modelProvider"], "gemini")
            self.assertEqual(data["trustedWorkspaces"], ["/ws/main", "/ws/probe"])

    def test_vertex_proxy_policy_sanitization_429_and_broken_pipe(self):
        upstream = _MockVertexUpstream()
        with tempfile.TemporaryDirectory() as tmp:
            port_file = Path(tmp) / "proxy.port"
            env = os.environ.copy()
            env["VERTEX_API_KEY"] = "test-secret-vertex-key"
            env["VERTEX_PROJECT_ID"] = ""
            env["VERTEX_UPSTREAM_BASE_URL"] = f"http://127.0.0.1:{upstream.port}"
            env["VERTEX_BACKOFF_SECS"] = "0.05,0.1"

            proc = subprocess.Popen(
                ["python3", str(WF_DIR / "vertex-proxy.py"), str(port_file)],
                env=env,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
            )
            try:
                for _ in range(50):
                    if port_file.is_file() and port_file.read_text().strip():
                        break
                    time.sleep(0.05)
                self.assertTrue(port_file.is_file(), "vertex-proxy.py did not write port file")
                proxy_port = int(port_file.read_text().strip())
                base_url = f"http://127.0.0.1:{proxy_port}"

                # 1. /healthz check
                with urllib.request.urlopen(f"{base_url}/healthz", timeout=5) as resp:
                    health = json.loads(resp.read().decode("utf-8"))
                self.assertEqual(health["allowed_models"], ["gemini-3.8-flash", "gemini-4-argon"])

                # 2. Gemini 4 Argon sanitization + project auto-discovery from 404
                argon_req_body = json.dumps(
                    {
                        "cachedContent": "caches/123",
                        "contents": [{"role": "user", "parts": [{"text": "hi"}]}],
                        "generationConfig": {
                            "temperature": 0.7,
                            "topP": 0.95,
                            "candidateCount": 2,
                            "thinkingConfig": {"thinkingBudget": 8192},
                        },
                    }
                ).encode("utf-8")
                req = urllib.request.Request(
                    f"{base_url}/v1beta/models/gemini-4-argon-high:streamGenerateContent",
                    data=argon_req_body,
                    headers={"Content-Type": "application/json"},
                    method="POST",
                )
                with urllib.request.urlopen(req, timeout=5) as resp:
                    self.assertEqual(resp.status, 200)

                last_call = upstream.calls[-1]
                self.assertIn(
                    "/projects/987654321/locations/global/publishers/google/models/gemini-4-argon:streamGenerateContent",
                    last_call["path"],
                )
                sanitized = last_call["body"]
                self.assertNotIn("cachedContent", sanitized)
                self.assertNotIn("temperature", sanitized["generationConfig"])
                self.assertNotIn("topP", sanitized["generationConfig"])
                self.assertEqual(sanitized["generationConfig"]["candidateCount"], 1)
                self.assertEqual(
                    sanitized["generationConfig"]["thinkingConfig"],
                    {"thinkingLevel": "HIGH"},
                )

                # 3. Internal flash-lite helper call rewritten to gemini-3.8-flash (LOW)
                lite_req = urllib.request.Request(
                    f"{base_url}/v1beta/models/gemini-3.1-flash-lite-preview:streamGenerateContent",
                    data=b'{"contents":[{"role":"user","parts":[{"text":"title"}]}]}',
                    headers={"Content-Type": "application/json"},
                    method="POST",
                )
                with urllib.request.urlopen(lite_req, timeout=5) as resp:
                    self.assertEqual(resp.status, 200)
                self.assertIn(
                    "/models/gemini-3.8-flash:streamGenerateContent",
                    upstream.calls[-1]["path"],
                )
                self.assertEqual(
                    upstream.calls[-1]["body"]["generationConfig"]["thinkingConfig"]["thinkingLevel"],
                    "LOW",
                )

                # 4. Strict rejection of disallowed models (e.g. gemini-4-carbon-high, gemini-3.1-pro-high)
                calls_before_reject = len(upstream.calls)
                for bad_model in ("gemini-4-carbon-high", "gemini-3.1-pro-high"):
                    bad_req = urllib.request.Request(
                        f"{base_url}/v1beta/models/{bad_model}:streamGenerateContent",
                        data=b'{"contents":[]}',
                        headers={"Content-Type": "application/json"},
                        method="POST",
                    )
                    with self.assertRaises(urllib.error.HTTPError) as ctx:
                        urllib.request.urlopen(bad_req, timeout=5)
                    self.assertEqual(ctx.exception.code, 400)
                self.assertEqual(
                    len(upstream.calls),
                    calls_before_reject,
                    "Disallowed models must NEVER reach upstream Vertex!",
                )

                # 5. /dryrun SSE & JSON validation without hitting upstream
                dry_req = urllib.request.Request(
                    f"{base_url}/dryrun/v1beta/models/gemini-3.8-flash-high:streamGenerateContent?alt=sse",
                    data=b'{"contents":[{"role":"user","parts":[{"text":"ok"}]}]}',
                    headers={"Content-Type": "application/json", "Accept": "text/event-stream"},
                    method="POST",
                )
                with urllib.request.urlopen(dry_req, timeout=5) as resp:
                    sse_text = resp.read().decode("utf-8")
                self.assertTrue(sse_text.startswith("data: "))
                self.assertEqual(len(upstream.calls), calls_before_reject)

                # 6. HTTP 429 retry recovery
                with upstream.lock:
                    upstream.rate_limit_remaining = 1
                rl_req = urllib.request.Request(
                    f"{base_url}/v1beta/models/gemini-3.8-flash-high:generateContent",
                    data=b'{"contents":[{"role":"user","parts":[{"text":"hi"}]}]}',
                    headers={"Content-Type": "application/json"},
                    method="POST",
                )
                with urllib.request.urlopen(rl_req, timeout=5) as resp:
                    self.assertEqual(resp.status, 200)

                # 7. BrokenPipeError simulation (client disconnects mid-TTFB): MUST NOT retry upstream!
                with upstream.lock:
                    upstream.mode = "slow_stream"
                    calls_before_disconnect = len(upstream.calls)

                raw_body = b'{"contents":[{"role":"user","parts":[{"text":"stream"}]}]}'
                with socket.create_connection(("127.0.0.1", proxy_port), timeout=5) as sock:
                    http_req = (
                        "POST /v1beta/models/gemini-4-argon-high:streamGenerateContent HTTP/1.1\r\n"
                        f"Host: 127.0.0.1:{proxy_port}\r\n"
                        "Content-Type: application/json\r\n"
                        f"Content-Length: {len(raw_body)}\r\n\r\n"
                    ).encode("utf-8") + raw_body
                    sock.sendall(http_req)
                    time.sleep(0.04)
                    # Abruptly close socket with RST/FIN before proxy finishes TTFB
                time.sleep(0.45)

                with upstream.lock:
                    calls_after_disconnect = len(upstream.calls)
                    upstream.mode = "normal"

                self.assertEqual(
                    calls_after_disconnect - calls_before_disconnect,
                    1,
                    "BrokenPipeError from disconnected client must NOT trigger upstream retries!",
                )

                with urllib.request.urlopen(f"{base_url}/healthz", timeout=5) as resp:
                    final_health = json.loads(resp.read().decode("utf-8"))
                self.assertGreaterEqual(final_health["stats"]["client_disconnects"], 1)
                self.assertEqual(final_health["stats"]["helper_rewrites"], 1)
            finally:
                proc.terminate()
                _, stderr_text = proc.communicate(timeout=5)
                upstream.close()

            self.assertNotIn(
                "Traceback (most recent call last)",
                stderr_text,
                f"Unhandled traceback in vertex-proxy.py stderr:\n{stderr_text}",
            )

    def test_verify_fork_driver_parser_backticks_and_dedup(self):
        script = WF_DIR / "verify-fork-driver.sh"
        with tempfile.TemporaryDirectory() as tmp:
            tdir = Path(tmp)

            # Case A: Layer 3 runtime failure with modern Cargo backticks
            raw_runtime = tdir / "raw_runtime.log"
            meta_a = tdir / "meta_a.env"
            rt_a = tdir / "rt_a.env"
            dig_a = tdir / "dig_a.log"
            raw_runtime.write_text(
                "running 3 tests\n"
                "test wayland::portal::tests::crop_bounds ... FAILED\n"
                "failures:\n"
                "thread 'wayland::portal::tests::crop_bounds' panicked at crates/platform-linux/src/wayland/mod.rs:100:5:\n"
                "assertion `left == right` failed\n"
                "error: test failed, to rerun pass `-p platform-linux --lib`\n",
                encoding="utf-8",
            )
            subprocess.run(
                [
                    "bash",
                    str(script),
                    "--selftest-parser",
                    str(raw_runtime),
                    "3",
                    str(meta_a),
                    str(rt_a),
                    str(dig_a),
                ],
                check=True,
            )
            parsed_meta_a = parse_shell_env_file(meta_a)
            parsed_rt_a = parse_shell_env_file(rt_a)
            self.assertEqual(parsed_meta_a["FAILED_KIND"], "runtime_test")
            self.assertEqual(parsed_rt_a["FAILED_RUNTIME_LAYER_ID"], "3")
            self.assertEqual(parsed_rt_a["FAILED_RERUN_SPEC"], "-p platform-linux --lib")
            self.assertEqual(
                parsed_rt_a["FAILED_TEST_FILTER"], "wayland::portal::tests::crop_bounds"
            )

            # Case B: Subsequent Layer 2 Clippy error with duplicate --all-targets blocks
            # MUST NOT overwrite sticky runtime target file rt_a!
            raw_clippy = tdir / "raw_clippy.log"
            meta_b = tdir / "meta_b.env"
            dig_b = tdir / "dig_b.log"
            dup_block = (
                "error: this `map_or` can be simplified\n"
                "  --> crates/platform-linux/src/wayland/mod.rs:4543:34\n"
                "   |\n"
                "4543 | let needs_main_pid = window.pid.map_or(true, |p| !is_main(p));\n"
                "   |                      ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^\n\n"
            )
            raw_clippy.write_text(
                dup_block
                + "error: could not compile `platform-linux` (lib) due to 1 previous error\n"
                + dup_block
                + "error: could not compile `platform-linux` (lib test) due to 1 previous error\n",
                encoding="utf-8",
            )
            subprocess.run(
                [
                    "bash",
                    str(script),
                    "--selftest-parser",
                    str(raw_clippy),
                    "2",
                    str(meta_b),
                    str(rt_a),
                    str(dig_b),
                ],
                check=True,
            )
            parsed_meta_b = parse_shell_env_file(meta_b)
            parsed_rt_still = parse_shell_env_file(rt_a)
            self.assertEqual(parsed_meta_b["FAILED_KIND"], "compile")
            self.assertEqual(parsed_meta_b["FAILED_PACKAGES"], "platform-linux")
            self.assertEqual(
                parsed_rt_still["FAILED_RERUN_SPEC"],
                "-p platform-linux --lib",
                "Layer 2 compile failure must preserve sticky Layer 3 runtime target!",
            )
            digest_text = dig_b.read_text(encoding="utf-8")
            # Header appears once in deduplicated section (plus at most in raw tail if short), check dedup header count:
            dedup_section = digest_text.split("==== Raw Log Tail")[0]
            self.assertEqual(
                dedup_section.count("error: this `map_or` can be simplified"),
                1,
                f"Expected duplicate --all-targets diagnostic to be deduplicated:\n{dedup_section}",
            )
            self.assertIn("==== Raw Log Tail", digest_text)

    def test_schedule_circuit_breaker_and_push_routing(self):
        lib_path = WF_DIR / "agy-sync-lib.sh"

        def check_skip(event: str, bodies: str, up_sha: str, st_sha: str) -> int:
            cmd = (
                f"source {shlex.quote(str(lib_path))} && "
                f"should_skip_exhausted_schedule {shlex.quote(event)} {shlex.quote(bodies)} "
                f"{shlex.quote(up_sha)} {shlex.quote(st_sha)}"
            )
            return subprocess.run(["bash", "-c", cmd]).returncode

        issue_body = "Alert text\n<!-- cua-sync-exhausted: up111:st222 -->\n"
        # Exact match on schedule -> skip (rc 0)
        self.assertEqual(check_skip("schedule", issue_body, "up111", "st222"), 0)
        # Upstream advanced -> must NOT skip (rc 1)
        self.assertEqual(check_skip("schedule", issue_body, "up999", "st222"), 1)
        # Target or Draft PR commit advanced -> must NOT skip (rc 1)
        self.assertEqual(check_skip("schedule", issue_body, "up111", "st888"), 1)
        # Manual workflow_dispatch -> must NEVER skip even on identical SHAs (rc 1)
        self.assertEqual(check_skip("workflow_dispatch", issue_body, "up111", "st222"), 1)

        sync_txt = (WF_DIR / "sync-upstream.yml").read_text(encoding="utf-8")
        self.assertIn("'libs/cua-driver/rust/**'", sync_txt)
        self.assertIn(
            "if: github.event_name == 'schedule' || (github.event_name == 'workflow_dispatch' && inputs.verify_ref == '')",
            sync_txt,
        )
        self.assertIn(
            "if: github.event_name == 'pull_request' || github.event_name == 'push' || inputs.verify_ref != ''",
            sync_txt,
        )

    def test_cargo_lock_conflict_auto_resolve_and_reconcile(self):
        lib_path = WF_DIR / "agy-sync-lib.sh"
        with tempfile.TemporaryDirectory() as tmp:
            repo = Path(tmp)
            subprocess.run(["git", "init", "-b", "main"], cwd=repo, check=True, capture_output=True)
            subprocess.run(["git", "config", "user.name", "Test"], cwd=repo, check=True)
            subprocess.run(["git", "config", "user.email", "test@example.com"], cwd=repo, check=True)

            (repo / "Cargo.toml").write_text(
                '[workspace]\nmembers = ["a", "b"]\nresolver = "2"\n', encoding="utf-8"
            )
            for crate in ("a", "b"):
                (repo / crate / "src").mkdir(parents=True)
                (repo / crate / "Cargo.toml").write_text(
                    f'[package]\nname = "{crate}"\nversion = "0.1.0"\nedition = "2021"\n',
                    encoding="utf-8",
                )
                (repo / crate / "src" / "lib.rs").write_text("pub fn f() {}\n", encoding="utf-8")

            has_cargo = subprocess.run(["bash", "-c", "command -v cargo"], capture_output=True).returncode == 0
            if has_cargo:
                subprocess.run(
                    ["cargo", "generate-lockfile", "--manifest-path", str(repo / "Cargo.toml")],
                    cwd=repo,
                    check=True,
                    capture_output=True,
                )
            else:
                (repo / "Cargo.lock").write_text("# v3\nversion = 3\n", encoding="utf-8")

            subprocess.run(["git", "add", "."], cwd=repo, check=True)
            subprocess.run(["git", "commit", "-m", "base"], cwd=repo, check=True, capture_output=True)

            # Fork adds dependency b -> a (updating Cargo.lock)
            subprocess.run(["git", "checkout", "-b", "fork"], cwd=repo, check=True, capture_output=True)
            (repo / "b" / "Cargo.toml").write_text(
                '[package]\nname = "b"\nversion = "0.1.0"\nedition = "2021"\n[dependencies]\na = { path = "../a" }\n',
                encoding="utf-8",
            )
            if has_cargo:
                subprocess.run(
                    ["cargo", "metadata", "--format-version", "1", "--manifest-path", str(repo / "Cargo.toml")],
                    cwd=repo,
                    check=True,
                    capture_output=True,
                )
            else:
                (repo / "Cargo.lock").write_text("# fork lock\nversion = 3\n", encoding="utf-8")
            subprocess.run(["git", "commit", "-am", "fork dep"], cwd=repo, check=True, capture_output=True)

            # Upstream bumps crate `a` to 0.2.0 AND touches `b` description so Cargo.lock has an overlapping hunk conflict!
            subprocess.run(["git", "checkout", "main"], cwd=repo, check=True, capture_output=True)
            (repo / "a" / "Cargo.toml").write_text(
                '[package]\nname = "a"\nversion = "0.2.0"\nedition = "2021"\n',
                encoding="utf-8",
            )
            (repo / "b" / "Cargo.toml").write_text(
                '[package]\nname = "b"\nversion = "0.2.0"\nedition = "2021"\n',
                encoding="utf-8",
            )
            if has_cargo:
                subprocess.run(
                    ["cargo", "metadata", "--format-version", "1", "--manifest-path", str(repo / "Cargo.toml")],
                    cwd=repo,
                    check=True,
                    capture_output=True,
                )
            else:
                (repo / "Cargo.lock").write_text("# upstream lock\nversion = 3\n", encoding="utf-8")
            subprocess.run(["git", "commit", "-am", "upstream bump"], cwd=repo, check=True, capture_output=True)

            # Merge main into fork: resolve b/Cargo.toml cleanly (keeping version 0.2.0 + dep on `a`) while Cargo.lock conflicts!
            subprocess.run(["git", "checkout", "fork"], cwd=repo, check=True, capture_output=True)
            subprocess.run(["git", "merge", "--no-commit", "--no-ff", "main"], cwd=repo, capture_output=True)
            unmerged_before = subprocess.check_output(
                ["git", "diff", "--name-only", "--diff-filter=U"], cwd=repo, text=True
            ).splitlines()
            self.assertIn("Cargo.lock", unmerged_before)

            # Simulate clean resolution of b/Cargo.toml (keeping both upstream 0.2.0 and fork dep `a`)
            (repo / "b" / "Cargo.toml").write_text(
                '[package]\nname = "b"\nversion = "0.2.0"\nedition = "2021"\n[dependencies]\na = { path = "../a" }\n',
                encoding="utf-8",
            )
            subprocess.run(["git", "add", "b/Cargo.toml"], cwd=repo, check=True)

            subprocess.run(
                [
                    "bash",
                    "-c",
                    f"source {shlex.quote(str(lib_path))} && auto_resolve_lockfile_conflicts && reconcile_rust_lockfiles Cargo.toml",
                ],
                cwd=repo,
                check=True,
            )

            unmerged_after = subprocess.check_output(
                ["git", "diff", "--name-only", "--diff-filter=U"], cwd=repo, text=True
            ).strip()
            self.assertEqual(unmerged_after, "")
            if has_cargo:
                locked_check = subprocess.run(
                    ["cargo", "metadata", "--locked", "--format-version", "1", "--manifest-path", str(repo / "Cargo.toml")],
                    cwd=repo,
                    capture_output=True,
                )
                self.assertEqual(locked_check.returncode, 0, "Cargo.lock must pass --locked after reconciliation!")

    def test_probe_vertex_retries_transient_read_timeout(self):
        upstream = _MockVertexUpstream()
        upstream.stall_remaining = 1
        try:
            env = os.environ.copy()
            env["VERTEX_API_KEY"] = "test-secret-vertex-key"
            env["VERTEX_PROJECT_ID"] = ""
            env["VERTEX_UPSTREAM_BASE_URL"] = f"http://127.0.0.1:{upstream.port}"
            env["VERTEX_PROBE_TIMEOUT_SECS"] = "0.1"
            env["VERTEX_BACKOFF_SECS"] = "0.05,0.1"

            res = subprocess.run(
                [
                    "python3",
                    str(WF_DIR / "vertex-proxy.py"),
                    "--probe-vertex",
                    "--models",
                    "gemini-3.8-flash,gemini-4-argon",
                ],
                env=env,
                capture_output=True,
                text=True,
                timeout=10,
            )
            self.assertEqual(res.returncode, 0, f"Expected probe retry to succeed, stderr:\n{res.stderr}")
            self.assertIn("OK gemini-3.8-flash", res.stdout)
            self.assertIn("OK gemini-4-argon", res.stdout)
            self.assertIn("Transient error on gemini-3.8-flash", res.stderr)
        finally:
            upstream.close()


if __name__ == "__main__":
    unittest.main(verbosity=2)
