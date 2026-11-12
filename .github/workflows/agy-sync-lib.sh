#!/usr/bin/env bash
# Shared foundation library for Sync Upstream Main & Verify Sync Infra workflows.
# Strictly enforces the two-model policy: Gemini 4 Argon + Gemini 3.8 Flash ONLY.

# Protected files under .github/workflows/ owned by this fork.
readonly FORK_PROTECTED_WORKFLOW_FILES=(
  ".github/workflows/sync-upstream.yml"
  ".github/workflows/verify-sync-infra.yml"
  ".github/workflows/verify-fork-driver.sh"
  ".github/workflows/vertex-proxy.py"
  ".github/workflows/agy-sync-lib.sh"
  ".github/workflows/test_sync_infra.py"
)

SYNC_BIN_DIR="${SYNC_BIN_DIR:-/tmp/cua-sync-bin}"
VERTEX_PROXY_PID="${VERTEX_PROXY_PID:-}"
VERTEX_PROXY_PORT="${VERTEX_PROXY_PORT:-}"
SUMMARY="${SUMMARY:-}"

is_protected_fork_workflow_file() {
  local candidate="$1"
  local item
  for item in "${FORK_PROTECTED_WORKFLOW_FILES[@]}"; do
    if [[ "${candidate}" == "${item}" ]]; then
      return 0
    fi
  done
  return 1
}

stage_sync_scripts_to_dir() {
  local dest="${1:-${SYNC_BIN_DIR}}"
  mkdir -p "${dest}"
  cp .github/workflows/verify-fork-driver.sh "${dest}/verify-fork-driver.sh"
  cp .github/workflows/vertex-proxy.py "${dest}/vertex-proxy.py"
  cp .github/workflows/agy-sync-lib.sh "${dest}/agy-sync-lib.sh"
  if [[ -f .github/workflows/test_sync_infra.py ]]; then
    cp .github/workflows/test_sync_infra.py "${dest}/test_sync_infra.py"
  fi
  chmod +x "${dest}/verify-fork-driver.sh" "${dest}/vertex-proxy.py" "${dest}/agy-sync-lib.sh"
}

prune_upstream_workflows() {
  local wf
  while IFS= read -r wf; do
    [[ -z "${wf}" ]] && continue
    if is_protected_fork_workflow_file "${wf}"; then
      git checkout --ours -- "${wf}" 2>/dev/null || true
      git add -- "${wf}" 2>/dev/null || true
    else
      git rm -f --ignore-unmatch -- "${wf}" >/dev/null 2>&1 || rm -f -- "${wf}"
    fi
  done < <(git diff --name-only --diff-filter=U -- '.github/workflows/' || true)

  while IFS= read -r wf; do
    [[ -z "${wf}" ]] && continue
    if ! is_protected_fork_workflow_file "${wf}"; then
      git rm -f --ignore-unmatch -- "${wf}" >/dev/null 2>&1 || rm -f -- "${wf}"
    fi
  done < <(find .github/workflows -maxdepth 2 -type f \( -name '*.yml' -o -name '*.yaml' \) 2>/dev/null || true)
}

stop_vertex_bridge() {
  if [[ -n "${VERTEX_PROXY_PID:-}" ]]; then
    kill "${VERTEX_PROXY_PID}" 2>/dev/null || true
    wait "${VERTEX_PROXY_PID}" 2>/dev/null || true
    VERTEX_PROXY_PID=""
  fi
  VERTEX_PROXY_PORT=""
  rm -f /tmp/vertex_proxy.port /tmp/vertex_proxy.port.tmp
}

start_vertex_bridge() {
  if [[ -n "${VERTEX_PROXY_PORT:-}" && -n "${VERTEX_PROXY_PID:-}" ]] && kill -0 "${VERTEX_PROXY_PID}" 2>/dev/null; then
    return 0
  fi

  stop_vertex_bridge

  local proxy_script="${SYNC_BIN_DIR}/vertex-proxy.py"
  if [[ ! -f "${proxy_script}" ]]; then
    proxy_script=".github/workflows/vertex-proxy.py"
  fi

  python3 "${proxy_script}" /tmp/vertex_proxy.port </dev/null >&2 &
  VERTEX_PROXY_PID=$!

  local _i
  for _i in {1..50}; do
    if [[ -s /tmp/vertex_proxy.port ]]; then
      break
    fi
    sleep 0.1
  done

  if [[ ! -s /tmp/vertex_proxy.port ]]; then
    echo "ERROR: Failed to start local Vertex AI bridge (port file not created)." >&2
    return 1
  fi

  VERTEX_PROXY_PORT=$(cat /tmp/vertex_proxy.port)
  if ! curl -fsS --max-time 5 "http://127.0.0.1:${VERTEX_PROXY_PORT}/healthz" >/dev/null; then
    echo "ERROR: Local Vertex AI bridge failed /healthz check on 127.0.0.1:${VERTEX_PROXY_PORT}." >&2
    stop_vertex_bridge
    return 1
  fi

  echo "Vertex AI strict 2-model bridge listening on 127.0.0.1:${VERTEX_PROXY_PORT} (allowed: gemini-4-argon, gemini-3.8-flash)"
  return 0
}

restart_vertex_bridge() {
  echo "🔄 Restarting local Vertex bridge to drop any orphaned streaming connections..."
  stop_vertex_bridge
  start_vertex_bridge
}

write_agy_trusted_settings() {
  local workspace_dir="$1"
  shift
  mkdir -p "$HOME/.gemini/antigravity-cli"
  local tmp_settings="$HOME/.gemini/antigravity-cli/settings.json.tmp"
  jq -n \
    --arg ws "${workspace_dir}" \
    '{modelProvider: "gemini", trustedWorkspaces: ([$ws] + $ARGS.positional)}' \
    --args -- "$@" > "${tmp_settings}" || return 1
  mv -f "${tmp_settings}" "$HOME/.gemini/antigravity-cli/settings.json"
}

install_agy_cli() {
  mkdir -p "$HOME/.local/bin"
  case ":$PATH:" in
    *":$HOME/.local/bin:"*) ;;
    *) export PATH="$HOME/.local/bin:$PATH" ;;
  esac

  if ! command -v agy >/dev/null 2>&1; then
    if ! curl -fsSL https://antigravity.google/cli/install.sh | bash -s -- -d "$HOME/.local/bin"; then
      echo "ERROR: Failed to download/install Antigravity CLI (install.sh)." >&2
      return 1
    fi
  fi
  if ! command -v agy >/dev/null 2>&1; then
    echo "ERROR: agy binary not found on PATH after installation." >&2
    return 1
  fi
  echo "Using Antigravity CLI: $(agy --version)"
  return 0
}

verify_agy_cli_two_models_dryrun() {
  start_vertex_bridge || return 1

  local probe_ws="/tmp/agy-dryrun-probe-ws"
  rm -rf "${probe_ws}"
  mkdir -p "${probe_ws}"
  write_agy_trusted_settings "${GITHUB_WORKSPACE:-$(pwd)}" "${probe_ws}"

  local model_flag rc status err_msg
  for model_flag in "gemini-4-argon-high" "gemini-3.8-flash-high"; do
    set +e
    (
      cd "${probe_ws}" &&
      GEMINI_API_KEY="${VERTEX_API_KEY:-dryrun-key}" \
      GOOGLE_GEMINI_BASE_URL="http://127.0.0.1:${VERTEX_PROXY_PORT}/dryrun" \
      NO_PROXY="127.0.0.1,localhost" \
      no_proxy="127.0.0.1,localhost" \
      AGY_CLI_DISABLE_AUTO_UPDATE="true" \
      agy -p "Reply with OK only." \
        --settings '{"modelProvider":"gemini"}' \
        --dangerously-skip-permissions \
        --output-format json \
        --print-timeout 30s \
        --model "${model_flag}" </dev/null >/tmp/agy_dryrun_out.json 2>/tmp/agy_dryrun_err.log
    )
    rc=$?
    set -e
    status=$(jq -r '.status // "ERROR"' /tmp/agy_dryrun_out.json 2>/dev/null || echo "ERROR")
    if [[ "${rc}" -ne 0 || "${status}" != "SUCCESS" ]]; then
      err_msg=$(jq -r '.error // empty' /tmp/agy_dryrun_out.json 2>/dev/null || true)
      if [[ -z "${err_msg}" ]]; then
        err_msg=$(tail -n 12 /tmp/agy_dryrun_err.log 2>/dev/null | tr '\n' ' ' || echo "exit ${rc}")
      fi
      echo "ERROR: agy CLI model preflight failed for --model '${model_flag}' (rc=${rc}, status=${status}): ${err_msg}" >&2
      rm -rf "${probe_ws}"
      return 1
    fi
    echo "✅ [preflight] agy CLI accepted --model ${model_flag} and completed dry-run roundtrip."
  done

  rm -rf "${probe_ws}"
  write_agy_trusted_settings "${GITHUB_WORKSPACE:-$(pwd)}"
  return 0
}

preflight_ai_toolchain() {
  local run_live_probe="${1:-true}"

  if [[ "${run_live_probe}" == "true" && -z "${VERTEX_API_KEY:-}" ]]; then
    echo "ERROR: VERTEX_API_KEY Secret is missing or empty." >&2
    return 1
  fi

  install_agy_cli || return 1

  VERTEX_API_KEY="${VERTEX_API_KEY:-dryrun-key}" start_vertex_bridge || return 1
  verify_agy_cli_two_models_dryrun || return 1

  if [[ "${run_live_probe}" == "true" ]]; then
    local proxy_script="${SYNC_BIN_DIR}/vertex-proxy.py"
    if [[ ! -f "${proxy_script}" ]]; then
      proxy_script=".github/workflows/vertex-proxy.py"
    fi
    echo "🔎 Probing live Vertex AI access for gemini-4-argon and gemini-3.8-flash..."
    if ! python3 "${proxy_script}" --probe-vertex --models "gemini-4-argon,gemini-3.8-flash"; then
      echo "ERROR: Live Vertex AI connectivity/quota probe failed for Argon or 3.8 Flash." >&2
      return 1
    fi
  fi

  return 0
}

workspace_snapshot_hash() {
  local scope="${AGY_EDIT_SCOPE:-.}"
  (
    git status --porcelain -- "${scope}" 2>/dev/null || true
    git diff -- "${scope}" 2>/dev/null || true
    git diff --cached -- "${scope}" 2>/dev/null || true
  ) | sha256sum | awk '{print $1}'
}

has_remaining_conflict_markers() {
  local cf
  while IFS= read -r cf; do
    if [[ -n "${cf}" && -f "${cf}" ]] && grep -nE '^(<<<<<<< |=======$|>>>>>>> )' -- "${cf}" >/dev/null 2>&1; then
      return 0
    fi
  done <<< "${CONFLICT_FILES:-}"

  local scope="${AGY_EDIT_SCOPE:-.}"
  while IFS= read -r cf; do
    if [[ -n "${cf}" && -f "${cf}" ]] && grep -nE '^(<<<<<<< |=======$|>>>>>>> )' -- "${cf}" >/dev/null 2>&1; then
      return 0
    fi
  done < <(
    {
      git diff --name-only -- "${scope}" 2>/dev/null || true
      git diff --cached --name-only -- "${scope}" 2>/dev/null || true
      git diff --name-only --diff-filter=U -- "${scope}" 2>/dev/null || true
    } | sort -u
  )

  return 1
}

invoke_agy_with_prompt() {
  local prompt_text="$1"
  local tier="${2:-deep}"
  local expect_edits="${3:-true}"
  local on_fail_fn="${4:-}"

  if [[ -z "${VERTEX_API_KEY:-}" ]]; then
    local msg="未配置 VERTEX_API_KEY Secret，无法启动 agy 自动修复冲突或测试失败。"
    if [[ -n "${on_fail_fn}" ]]; then "${on_fail_fn}" "${msg}"; fi
    return 1
  fi

  install_agy_cli || {
    local msg="安装或检查 Antigravity CLI (agy) 失败。"
    if [[ -n "${on_fail_fn}" ]]; then "${on_fail_fn}" "${msg}"; fi
    return 1
  }
  start_vertex_bridge || {
    local msg="启动本地 Vertex AI 双模型路由代理失败。"
    if [[ -n "${on_fail_fn}" ]]; then "${on_fail_fn}" "${msg}"; fi
    return 1
  }
  write_agy_trusted_settings "${PWD}"

  local before_hash
  before_hash=$(workspace_snapshot_hash)

  # STRICT TWO-MODEL POLICY: ONLY Gemini 4 Argon & Gemini 3.8 Flash.
  local -a candidates=()
  if [[ "${tier}" == "fast" ]]; then
    candidates=(
      "gemini-3.8-flash-high|8m"
      "gemini-4-argon-high|10m"
    )
  else
    candidates=(
      "gemini-4-argon-high|10m"
      "gemini-3.8-flash-high|8m"
    )
  fi

  local agy_rc=1
  local json_status="ERROR"
  local after_hash=""
  local last_err=""
  local idx=0
  local total="${#candidates[@]}"
  local entry cand_model cand_tmo

  set +e
  for entry in "${candidates[@]}"; do
    idx=$((idx + 1))
    cand_model="${entry%%|*}"
    cand_tmo="${entry##*|}"
    echo "🤖 [agy:${tier}] (${idx}/${total}) Invoking ${cand_model} (timeout ${cand_tmo})..."

    GEMINI_API_KEY="${VERTEX_API_KEY}" \
    GOOGLE_GEMINI_BASE_URL="http://127.0.0.1:${VERTEX_PROXY_PORT}" \
    NO_PROXY="127.0.0.1,localhost" \
    no_proxy="127.0.0.1,localhost" \
    AGY_CLI_DISABLE_AUTO_UPDATE="true" \
    agy -p "${prompt_text}" \
      --settings '{"modelProvider":"gemini"}' \
      --dangerously-skip-permissions \
      --output-format json \
      --print-timeout "${cand_tmo}" \
      --model "${cand_model}" </dev/null >/tmp/agy_stdout.json 2>/tmp/agy_stderr.log
    agy_rc=$?

    json_status=$(jq -r '.status // "ERROR"' /tmp/agy_stdout.json 2>/dev/null || echo "ERROR")
    after_hash=$(workspace_snapshot_hash)

    if [[ "${agy_rc}" -eq 3 ]]; then
      # Sever any orphaned streaming connections from the timed-out agy process immediately.
      restart_vertex_bridge || true
    fi

    if [[ "${agy_rc}" -eq 0 && "${json_status}" == "SUCCESS" ]]; then
      if has_remaining_conflict_markers; then
        last_err="${cand_model} returned SUCCESS but Git conflict markers still remain"
        echo "⚠️ [agy:${cand_model}] ${last_err}; trying remaining pair model..."
      elif [[ "${expect_edits}" == "true" && "${after_hash}" == "${before_hash}" ]]; then
        last_err="${cand_model} returned SUCCESS without modifying target workspace files"
        echo "⚠️ [agy:${cand_model}] ${last_err}; trying remaining pair model..."
      else
        SUMMARY=$(jq -r '.response // ""' /tmp/agy_stdout.json)
        echo "✅ [agy:${cand_model}] Completed edits cleanly."
        set -e
        return 0
      fi
    elif [[ "${agy_rc}" -eq 3 && "${after_hash}" != "${before_hash}" ]] && ! has_remaining_conflict_markers; then
      echo "⚠️ [agy:${cand_model}] Hit print-timeout (${cand_tmo}) after writing clean workspace edits; proceeding to outer deterministic verification..."
      SUMMARY=$(jq -r '.response // "已完成代码修复（外层流水线继续执行格式化与 5 层测试校验）。"' /tmp/agy_stdout.json 2>/dev/null || echo "已完成代码修复。")
      set -e
      return 0
    else
      last_err=$(jq -r '.error // empty' /tmp/agy_stdout.json 2>/dev/null || true)
      if [[ -z "${last_err}" ]]; then
        last_err=$(tail -n 8 /tmp/agy_stderr.log 2>/dev/null | tr '\n' ' ' || echo "exit code ${agy_rc}")
      fi
      echo "⚠️ [agy:${cand_model}] Unsuccessful (exit=${agy_rc}, status=${json_status}): ${last_err:0:260}"
    fi

    if [[ "${idx}" -lt "${total}" ]]; then
      sleep 2
    fi
  done
  set -e

  cat /tmp/agy_stderr.log >&2 || true
  local fail_reason="agy 双模型链（${tier}: Argon + 3.8 Flash）均未完成有效修复（exit ${agy_rc} / ${json_status}）：${last_err}"
  if [[ -n "${on_fail_fn}" ]]; then
    "${on_fail_fn}" "${fail_reason}"
  fi
  return 1
}
