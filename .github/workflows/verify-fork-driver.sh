#!/usr/bin/env bash
# Bidirectional compile, Clippy, unit/contract, Wayland portal, and headless
# X11/GTK3 AT-SPI regression suite for ymqy/cua (feat/wayland-with-perception-opt).
#
# Outputs:
#   /tmp/verify_report.md   - Markdown summary table of all 5 layers
#   /tmp/verify_failure.log - Tail of compiler/test output when a layer fails

set -euo pipefail

REPO_ROOT=$(git rev-parse --show-toplevel)
RUST_WS="${REPO_ROOT}/libs/cua-driver/rust"
REPORT_FILE="${VERIFY_REPORT_FILE:-/tmp/verify_report.md}"
FAILURE_LOG="${VERIFY_FAILURE_LOG:-/tmp/verify_failure.log}"
RAW_LOG="/tmp/verify_step_raw.log"
LAST_FAIL_ENV="/tmp/verify_last_failure.env"

rm -f "${REPORT_FILE}" "${FAILURE_LOG}" "${RAW_LOG}"

if [[ ! -d "${RUST_WS}" ]]; then
  echo "Error: Rust workspace not found at ${RUST_WS}" | tee "${FAILURE_LOG}" >&2
  exit 1
fi

cd "${RUST_WS}"

declare -a LAYER_ROWS=()
SUITE_START=$(date +%s)

record_failure_metadata() {
  local layer_id="$1"
  python3 - "${RAW_LOG}" "${layer_id}" > "${LAST_FAIL_ENV}" <<'PY'
import re
import shlex
import sys

raw_path, layer_id = sys.argv[1], sys.argv[2]
try:
    with open(raw_path, "r", encoding="utf-8", errors="replace") as fh:
        text = fh.read()
except Exception:
    text = ""

has_compile_err = bool(re.search(r"(?m)^error(\[E\d+\]|: could not compile)", text))
kind = "compile" if (layer_id in ("1", "2") or has_compile_err) else "runtime_test"

reruns = []
for m in re.finditer(r"error: test failed, to rerun pass '([^']+)'", text):
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

print(f"FAILED_LAYER_ID={shlex.quote(layer_id)}")
print(f"FAILED_KIND={shlex.quote(kind)}")
print(f"FAILED_RERUN_SPEC={shlex.quote(rerun_spec)}")
print(f"FAILED_TEST_FILTER={shlex.quote(test_filter)}")
print(f"FAILED_TESTS_JOINED={shlex.quote(' '.join(tests[:8]))}")
PY
}

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
    record_failure_metadata "${layer_id}" || true
    {
      echo "Failed layer: [${layer_id}] ${layer_title} (exit ${rc})"
      echo "Full raw log path: ${RAW_LOG}"
      echo "==== Key Error / Panic / Diff Blocks ===="
      grep -n -C 10 -E '^(error(\[|:)|FAILED|thread .* panicked|Diff in )' "${RAW_LOG}" | head -n 260 || true
      echo ""
      echo "==== Raw Log Tail (last 160 lines) ===="
      tail -n 160 "${RAW_LOG}"
    } > "${FAILURE_LOG}"
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

if [[ -f "${LAST_FAIL_ENV}" ]]; then
  FAILED_LAYER_ID=""
  FAILED_RERUN_SPEC=""
  FAILED_TEST_FILTER=""
  FAILED_TESTS_JOINED=""
  # shellcheck disable=SC1090
  source "${LAST_FAIL_ENV}"

  SAVED_ROWS=("${LAYER_ROWS[@]}")
  if [[ "${FAILED_LAYER_ID}" == "3" && -n "${FAILED_RERUN_SPEC}" ]]; then
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
    rm -f "${LAST_FAIL_ENV}"
    LAYER_ROWS=("${SAVED_ROWS[@]}")
  elif [[ "${FAILED_LAYER_ID}" == "4" ]]; then
    run_layer "4" "Wayland Portal 极速复测" \
      "定向快速验证 Wayland Portal 修复（通过后继续全量 5 层回归认证）" \
      layer_4_wayland_portal_tests
    rm -f "${LAST_FAIL_ENV}"
    LAYER_ROWS=("${SAVED_ROWS[@]}")
  elif [[ "${FAILED_LAYER_ID}" == "5" ]]; then
    run_layer "5" "无头桌面与 GTK3/AT-SPI 极速复测" \
      "定向快速验证 X11/GTK3 AT-SPI 修复（通过后继续全量 5 层回归认证）" \
      layer_5_headless_desktop_and_gtk_atspi
    rm -f "${LAST_FAIL_ENV}"
    LAYER_ROWS=("${SAVED_ROWS[@]}")
  fi
fi

run_layer "2" "全工作区与 Wayland Portal 静态编译检查" \
  "全 crates/tests Clippy (-D warnings) + portal-input/portal-capture 交叉编译签名校验" \
  layer_2_clippy_and_features

run_layer "3" "上游契约与定制模块双向单元测试" \
  "cua-perception 无损/批处理推理 + cua-driver-core Wayland/CDP + platform-linux 拖拽/历史 + 契约测试" \
  layer_3_bidirectional_unit_tests

run_layer "4" "Wayland Portal 特性单元测试" \
  "platform-linux (portal-input + portal-capture) PipeWire 窗口裁剪与 libei 输入逻辑" \
  layer_4_wayland_portal_tests

run_layer "5" "无头桌面输入与 GTK3/AT-SPI 菜单回归测试" \
  "Xvfb + D-Bus + Openbox 真实点击/按键时序 + GTK3 后台菜单激活与防吞键回归 (native.rs)" \
  layer_5_headless_desktop_and_gtk_atspi

rm -f "${LAST_FAIL_ENV}"
write_report "PASSED"
echo ""
cat "${REPORT_FILE}"
