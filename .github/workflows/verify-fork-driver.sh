#!/usr/bin/env bash
# Bidirectional compile, Clippy, unit/contract, Wayland portal, and headless
# X11/GTK3 AT-SPI regression suite for ymqy/cua (feat/wayland-with-perception-opt).
#
# Outputs:
#   /tmp/verify_report.md               - Markdown summary table of all 5 layers
#   /tmp/verify_failure.log             - Deduplicated, compact compiler/test failure digest
#   /tmp/verify_last_failure.env        - Current failure kind + signature (for tier escalation)
#   /tmp/verify_last_runtime_target.env - Sticky runtime target (Layers 3/4/5) for fail-fast rerun

set -euo pipefail

REPORT_FILE="${VERIFY_REPORT_FILE:-/tmp/verify_report.md}"
FAILURE_LOG="${VERIFY_FAILURE_LOG:-/tmp/verify_failure.log}"
RAW_LOG="${VERIFY_RAW_LOG:-/tmp/verify_step_raw.log}"
LAST_FAIL_ENV="${VERIFY_LAST_FAIL_ENV:-/tmp/verify_last_failure.env}"
LAST_RUNTIME_ENV="${VERIFY_LAST_RUNTIME_ENV:-/tmp/verify_last_runtime_target.env}"

extract_failure_artifacts() {
  local raw_path="$1"
  local layer_id="$2"
  local layer_title="$3"
  local exit_rc="$4"
  local meta_out="$5"
  local runtime_out="$6"
  local digest_out="$7"

  python3 - "${raw_path}" "${layer_id}" "${layer_title}" "${exit_rc}" "${meta_out}" "${runtime_out}" "${digest_out}" <<'PY'
import hashlib
import re
import shlex
import sys

raw_path, layer_id, layer_title, exit_rc, meta_out, runtime_out, digest_out = sys.argv[1:8]
try:
    with open(raw_path, "r", encoding="utf-8", errors="replace") as fh:
        text = fh.read()
except Exception:
    text = ""

lines = text.splitlines()

has_compile_err = bool(re.search(r"(?m)^error(\[E\d+\]|: )", text)) and not bool(
    re.search(r"(?m)^error: test failed, to rerun pass ", text)
    and not re.search(r"(?m)^error(\[E\d+\]|: (?!test failed|could not compile))", text)
)
if layer_id in ("1", "2"):
    kind = "compile"
elif re.search(r"(?m)^error(\[E\d+\]|: could not compile)", text):
    kind = "compile"
else:
    kind = "runtime_test"

reruns = []
for m in re.finditer(r"error: test failed, to rerun pass [`']([^`']+)[`']", text):
    spec = m.group(1).strip()
    if spec and spec not in reruns:
        reruns.append(spec)

tests = []
for m in re.finditer(r"(?m)^test (\S+) \.\.\. FAILED$", text):
    t = m.group(1).strip()
    if t and t not in tests:
        tests.append(t)

rerun_spec = reruns[0] if len(reruns) == 1 else ""
test_filter = ""
if tests:
    if len(tests) == 1:
        test_filter = tests[0]
    else:
        parts = [t.split("::") for t in tests]
        common = []
        for segs in zip(*parts):
            if len(set(segs)) == 1:
                common.append(segs[0])
            else:
                break
        if common:
            test_filter = "::".join(common)

# Extract deduplicated compiler/Clippy error blocks (eliminates --all-targets lib + test duplicates).
diag_blocks = []
seen_keys = set()
i = 0
n = len(lines)
while i < n:
    line = lines[i]
    if re.match(r"^error(\[E\d+\]|: )", line):
        if line.startswith("error: could not compile ") or line.startswith("error: aborting due to "):
            i += 1
            continue
        block = [line]
        j = i + 1
        while j < n and j < i + 18:
            nxt = lines[j]
            if re.match(r"^(error|warning)(\[|:)", nxt) or nxt.startswith("   Compiling ") or nxt.startswith("    Checking "):
                break
            block.append(nxt)
            if nxt.strip() == "" and len(block) >= 4:
                j += 1
                break
            j += 1
        key = "\n".join(l.strip() for l in block[:4])
        if key not in seen_keys:
            seen_keys.add(key)
            diag_blocks.append("\n".join(block).rstrip())
        i = j
    else:
        i += 1

panic_blocks = []
for idx, line in enumerate(lines):
    if re.search(r"(thread '.*' panicked at|Diff in |^failures:$)", line):
        start = max(0, idx - 2)
        end = min(n, idx + 14)
        snippet = "\n".join(lines[start:end]).rstrip()
        if snippet not in panic_blocks:
            panic_blocks.append(snippet)

sig_basis = "\n".join(sorted(seen_keys)) or "\n".join(tests) or "\n".join(lines[-25:])
sig = hashlib.sha256(f"{layer_id}:{kind}:{sig_basis}".encode("utf-8")).hexdigest()[:16]

with open(meta_out, "w", encoding="utf-8") as mf:
    mf.write(f"FAILED_LAYER_ID={shlex.quote(layer_id)}\n")
    mf.write(f"FAILED_KIND={shlex.quote(kind)}\n")
    mf.write(f"FAILED_SIGNATURE={shlex.quote(sig)}\n")

if kind == "runtime_test" and layer_id in ("3", "4", "5"):
    with open(runtime_out, "w", encoding="utf-8") as rf:
        rf.write(f"FAILED_RUNTIME_LAYER_ID={shlex.quote(layer_id)}\n")
        rf.write(f"FAILED_RERUN_SPEC={shlex.quote(rerun_spec)}\n")
        rf.write(f"FAILED_TEST_FILTER={shlex.quote(test_filter)}\n")
        rf.write(f"FAILED_TESTS_JOINED={shlex.quote(' '.join(tests[:8]))}\n")

out_lines = [
    f"Failed layer: [{layer_id}] {layer_title} (exit {exit_rc}, kind={kind}, sig={sig})",
]
if tests:
    out_lines.append(f"Failed tests: {', '.join(tests[:12])}")
if rerun_spec:
    out_lines.append(f"Cargo rerun spec: {rerun_spec}")

if diag_blocks:
    out_lines.append("==== Deduplicated Compiler / Clippy Errors ====")
    budget = 135
    used = 0
    for blk in diag_blocks:
        blk_lines = blk.splitlines()
        if used + len(blk_lines) > budget and used > 0:
            out_lines.append(f"... ({len(diag_blocks)} unique error blocks total; remaining omitted)")
            break
        out_lines.extend(blk_lines)
        out_lines.append("")
        used += len(blk_lines) + 1

if panic_blocks:
    out_lines.append("==== Panic / Assertion / Formatting Diff Blocks ====")
    budget = 65
    used = 0
    for blk in panic_blocks:
        blk_lines = blk.splitlines()
        if used + len(blk_lines) > budget and used > 0:
            break
        out_lines.extend(blk_lines)
        out_lines.append("")
        used += len(blk_lines) + 1

tail_count = 45 if (diag_blocks or panic_blocks) else 120
out_lines.append(f"==== Raw Log Tail (last {tail_count} lines) ====")
out_lines.extend(lines[-tail_count:])

with open(digest_out, "w", encoding="utf-8") as df:
    df.write("\n".join(out_lines) + "\n")
PY
}

if [[ "${1:-}" == "--selftest-parser" ]]; then
  # Usage: verify-fork-driver.sh --selftest-parser <raw_log> <layer_id> <meta_out> <runtime_out> <digest_out>
  extract_failure_artifacts "$2" "$3" "selftest" "101" "$4" "$5" "$6"
  exit 0
fi

REPO_ROOT=$(git rev-parse --show-toplevel)
RUST_WS="${REPO_ROOT}/libs/cua-driver/rust"

rm -f "${REPORT_FILE}" "${FAILURE_LOG}" "${RAW_LOG}"

if [[ ! -d "${RUST_WS}" ]]; then
  echo "Error: Rust workspace not found at ${RUST_WS}" | tee "${FAILURE_LOG}" >&2
  exit 1
fi

cd "${RUST_WS}"

declare -a LAYER_ROWS=()
SUITE_START=$(date +%s)

run_layer() {
  local layer_id="$1"
  local layer_title="$2"
  local layer_scope="$3"
  shift 3

  echo ""
  echo "================================================================================"
  echo "▶ [${layer_id}] ${layer_title}"
  echo "  覆盖范围: ${layer_scope}"
  echo "================================================================================"

  local t0 t1 elapsed rc tail_pid
  t0=$(date +%s)
  : > "${RAW_LOG}"
  tail -n +1 -f "${RAW_LOG}" &
  tail_pid=$!

  set +e
  (
    set -euo pipefail
    "$@"
  ) > "${RAW_LOG}" 2>&1
  rc=$?
  set -e

  sleep 0.2
  kill "${tail_pid}" 2>/dev/null || true
  wait "${tail_pid}" 2>/dev/null || true

  t1=$(date +%s)
  elapsed=$((t1 - t0))

  if [[ "${rc}" -eq 0 ]]; then
    echo "✅ [${layer_id}] 通过 (${elapsed}s)"
    LAYER_ROWS+=("| ✅ 通过 | **${layer_id}. ${layer_title}** | ${layer_scope} | ${elapsed}s |")
  else
    echo "❌ [${layer_id}] 失败 (exit ${rc}, ${elapsed}s)" >&2
    LAYER_ROWS+=("| ❌ 失败 | **${layer_id}. ${layer_title}** | ${layer_scope} | ${elapsed}s |")
    extract_failure_artifacts "${RAW_LOG}" "${layer_id}" "${layer_title}" "${rc}" \
      "${LAST_FAIL_ENV}" "${LAST_RUNTIME_ENV}" "${FAILURE_LOG}" || true
    write_report "FAILED" "${layer_id}. ${layer_title}"
    exit "${rc}"
  fi
}

write_report() {
  local overall="$1"
  local failed_at="${2:-}"
  local suite_end total_elapsed tested_sha
  suite_end=$(date +%s)
  total_elapsed=$((suite_end - SUITE_START))
  tested_sha=$(git rev-parse --short HEAD)

  {
    if [[ "${overall}" == "PASSED" ]]; then
      echo "### 🧪 自动编译与双向回归测试结果（全部通过 ✅ · \`${tested_sha}\` · 共 ${total_elapsed}s）"
    else
      echo "### 🧪 自动编译与双向回归测试结果（未通过 ❌ · 失败于 ${failed_at} · \`${tested_sha}\`）"
    fi
    echo ""
    echo "| 状态 | 测试层级 | 双向验证覆盖面（上游主干 ↔ 本分支 Wayland / Perception 定制） | 耗时 |"
    echo "| :--- | :--- | :--- | :--- |"
    for row in "${LAYER_ROWS[@]}"; do
      echo "${row}"
    done
  } > "${REPORT_FILE}"
}

layer_1_fmt_and_graph() {
  cargo fmt --all -- --check

  local graph
  graph=$(cargo tree --locked -p cua-driver -e features -i atspi-connection --prefix none)
  if grep -q '^atspi-connection feature "p2p"' <<<"${graph}"; then
    echo "ERROR: cua-driver resolves atspi-connection with forbidden p2p feature" >&2
    exit 1
  fi
}

layer_2_clippy_and_features() {
  cargo clippy --locked --workspace --all-targets --keep-going -- -D warnings
  cargo clippy --locked -p platform-linux --features portal-input,portal-capture --all-targets --keep-going -- -D warnings
  cargo check --locked -p cua-driver --features portal-input --keep-going
}

layer_3_bidirectional_unit_tests() {
  cargo build --locked -p cua-driver --bin cua-driver
  timeout --kill-after=15s 900s env CUA_TEST_REQUIRE_DRIVER_BIN=1 cargo test --locked \
    -p cua-driver \
    -p cua-driver-core \
    -p cua-driver-contract \
    -p cua-driver-testkit \
    -p cua-perception \
    -p platform-linux \
    -p cursor-overlay \
    -p cua-cursor-motion \
    --all-targets
}

layer_4_wayland_portal_tests() {
  timeout --kill-after=15s 300s \
    cargo test --locked -p platform-linux --features portal-input,portal-capture --lib
}

layer_5_headless_desktop_and_gtk_atspi() {
  cargo test -p platform-linux --test click_input_x11 --test key_input_x11 --locked --no-run

  timeout --kill-after=10s 180s \
    xvfb-run -a --server-args="-screen 0 640x480x24 -noreset" \
      cargo test -p platform-linux --test click_input_x11 --locked -- \
        --ignored --nocapture --test-threads=1

  timeout --kill-after=10s 180s \
    xvfb-run -a \
      cargo test -p platform-linux --test key_input_x11 --locked -- \
        --ignored --nocapture --test-threads=1

  if [[ -f crates/platform-linux/tests/background_menu_xorg.rs ]]; then
    cargo test -p platform-linux --test background_menu_xorg --locked --no-run
    # shellcheck disable=SC2016
    timeout --kill-after=10s 180s \
      xvfb-run -a --server-args="-screen 0 1280x800x24 -noreset" \
        dbus-run-session -- bash -c '
          set -euo pipefail
          export XDG_SESSION_TYPE=x11
          export GDK_BACKEND=x11
          export GTK_MODULES=gail:atk-bridge
          export NO_AT_BRIDGE=0

          ATSPI_LAUNCHER=""
          for cand in /usr/libexec/at-spi-bus-launcher /usr/lib/at-spi2-core/at-spi-bus-launcher "$(command -v at-spi-bus-launcher || true)"; do
            if [[ -n "${cand}" && -x "${cand}" ]]; then
              ATSPI_LAUNCHER="${cand}"
              break
            fi
          done

          ATSPI_PID=""
          if [[ -n "${ATSPI_LAUNCHER}" ]]; then
            ATSPI_DBUS_IMPLEMENTATION=dbus-daemon "${ATSPI_LAUNCHER}" --launch-immediately >/tmp/cua-verify-atspi.log 2>&1 &
            ATSPI_PID=$!
            for _ in {1..50}; do
              if gdbus call --session --dest org.a11y.Bus --object-path /org/a11y/bus --method org.a11y.Bus.GetAddress >/dev/null 2>&1; then
                break
              fi
              sleep 0.2
            done
          fi

          openbox >/tmp/cua-verify-openbox.log 2>&1 &
          OB_PID=$!
          cleanup() {
            kill "${OB_PID}" 2>/dev/null || true
            if [[ -n "${ATSPI_PID}" ]]; then
              kill "${ATSPI_PID}" 2>/dev/null || true
            fi
          }
          trap cleanup EXIT
          sleep 1
          cargo test -p platform-linux --test background_menu_xorg --locked -- \
            --ignored --nocapture --test-threads=1
        '
  fi
}

run_layer "1" "代码格式与依赖图守卫" \
  "rustfmt 格式一致性 + AT-SPI 无 p2p 特性泄漏契约" \
  layer_1_fmt_and_graph

run_layer "2" "全工作区与 Wayland Portal 静态编译检查" \
  "全 crates/tests Clippy (-D warnings) + portal-input/portal-capture 交叉编译签名校验" \
  layer_2_clippy_and_features

# Fail-fast targeted runtime precheck: runs AFTER static Clippy passes so compile mistakes
# never wipe the sticky runtime target, and BEFORE full 8-crate Layer 3 execution.
SKIP_LAYER_4="false"
SKIP_LAYER_5="false"

if [[ -f "${LAST_RUNTIME_ENV}" ]]; then
  FAILED_RUNTIME_LAYER_ID=""
  FAILED_RERUN_SPEC=""
  FAILED_TEST_FILTER=""
  FAILED_TESTS_JOINED=""
  # shellcheck disable=SC1090
  source "${LAST_RUNTIME_ENV}"

  SAVED_ROWS=("${LAYER_ROWS[@]}")
  if [[ "${FAILED_RUNTIME_LAYER_ID}" == "3" && -n "${FAILED_RERUN_SPEC}" ]]; then
    read -r -a SPEC_ARGS <<< "${FAILED_RERUN_SPEC}"
    layer_3_targeted_precheck() {
      cargo build --locked -p cua-driver --bin cua-driver
      if [[ -n "${FAILED_TEST_FILTER}" ]]; then
        timeout --kill-after=10s 180s env CUA_TEST_REQUIRE_DRIVER_BIN=1 \
          cargo test --locked "${SPEC_ARGS[@]}" -- "${FAILED_TEST_FILTER}"
      elif [[ -n "${FAILED_TESTS_JOINED}" ]]; then
        cargo test --locked "${SPEC_ARGS[@]}" --no-run
        local single_test
        for single_test in ${FAILED_TESTS_JOINED}; do
          timeout --kill-after=10s 120s env CUA_TEST_REQUIRE_DRIVER_BIN=1 \
            cargo test --locked "${SPEC_ARGS[@]}" -- "${single_test}"
        done
      else
        timeout --kill-after=10s 240s env CUA_TEST_REQUIRE_DRIVER_BIN=1 \
          cargo test --locked "${SPEC_ARGS[@]}"
      fi
    }
    run_layer "3" "上次失败单测极速复测 (${FAILED_RERUN_SPEC})" \
      "定向快速验证本轮修复是否已消除上次失败断言（通过后继续全量 5 层回归认证）" \
      layer_3_targeted_precheck
    rm -f "${LAST_RUNTIME_ENV}"
    LAYER_ROWS=("${SAVED_ROWS[@]}")
  elif [[ "${FAILED_RUNTIME_LAYER_ID}" == "4" ]]; then
    run_layer "4" "Wayland Portal 特性单元测试（定向优先复测）" \
      "platform-linux (portal-input + portal-capture) PipeWire 窗口裁剪与 libei 输入逻辑" \
      layer_4_wayland_portal_tests
    rm -f "${LAST_RUNTIME_ENV}"
    LAYER_ROWS=("${SAVED_ROWS[@]}")
    SKIP_LAYER_4="true"
  elif [[ "${FAILED_RUNTIME_LAYER_ID}" == "5" ]]; then
    run_layer "5" "无头桌面与 GTK3/AT-SPI 优先复测" \
      "定向优先验证 X11/GTK3 AT-SPI 修复（通过后补跑完整单元测试认证）" \
      layer_5_headless_desktop_and_gtk_atspi
    rm -f "${LAST_RUNTIME_ENV}"
    LAYER_ROWS=("${SAVED_ROWS[@]}")
    SKIP_LAYER_5="true"
  fi
fi

run_layer "3" "上游契约与定制模块双向单元测试" \
  "cua-perception 无损/批处理推理 + cua-driver-core Wayland/CDP + platform-linux 拖拽/历史 + 契约测试" \
  layer_3_bidirectional_unit_tests

if [[ "${SKIP_LAYER_4}" == "true" ]]; then
  LAYER_ROWS+=("| ✅ 通过 | **4. Wayland Portal 特性单元测试** | platform-linux (portal-input + portal-capture) PipeWire 窗口裁剪与 libei 输入逻辑（已在优先复测中通过） | - |")
else
  run_layer "4" "Wayland Portal 特性单元测试" \
    "platform-linux (portal-input + portal-capture) PipeWire 窗口裁剪与 libei 输入逻辑" \
    layer_4_wayland_portal_tests
fi

if [[ "${SKIP_LAYER_5}" == "true" ]]; then
  LAYER_ROWS+=("| ✅ 通过 | **5. 无头桌面输入与 GTK3/AT-SPI 菜单回归测试** | Xvfb + D-Bus + Openbox 真实点击/按键时序 + GTK3 后台菜单激活与防吞键回归（已在优先复测中通过） | - |")
else
  run_layer "5" "无头桌面输入与 GTK3/AT-SPI 菜单回归测试" \
    "Xvfb + D-Bus + Openbox 真实点击/按键时序 + GTK3 后台菜单激活与防吞键回归 (native.rs)" \
    layer_5_headless_desktop_and_gtk_atspi
fi

rm -f "${LAST_FAIL_ENV}" "${LAST_RUNTIME_ENV}"
write_report "PASSED"
echo ""
cat "${REPORT_FILE}"
