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

auto_resolve_lockfile_conflicts() {
  # Resolve Cargo.lock Git conflicts deterministically using upstream (--theirs) baseline
  # so LLM tokens are never wasted hand-editing multi-thousand-line lockfiles & checksums.
  # Call reconcile_rust_lockfiles once Cargo is available to sync lockfiles with Cargo.toml.
  local lf
  LOCKFILE_CONFLICTS_RESOLVED="${LOCKFILE_CONFLICTS_RESOLVED:-false}"
  while IFS= read -r lf; do
    [[ -z "${lf}" ]] && continue
    if [[ "${lf}" == "Cargo.lock" || "${lf}" == */Cargo.lock ]]; then
      if git checkout --theirs -- "${lf}" 2>/dev/null || git checkout --ours -- "${lf}" 2>/dev/null; then
        git add -- "${lf}"
        LOCKFILE_CONFLICTS_RESOLVED="true"
        echo "🔒 Auto-resolved Cargo.lock conflict via deterministic baseline: ${lf}"
      fi
    fi
  done < <(git diff --name-only --diff-filter=U || true)
  export LOCKFILE_CONFLICTS_RESOLVED
}

reconcile_rust_lockfiles() {
  # Minimally reconcile Cargo.lock when workspace Cargo.toml dependencies changed during merge/repair,
  # preventing `--locked` verification deadlocks while keeping existing pinned versions intact.
  if ! command -v cargo >/dev/null 2>&1; then
    return 0
  fi

  local manifest
  for manifest in "$@"; do
    [[ -z "${manifest}" || ! -f "${manifest}" ]] && continue
    if cargo metadata --locked --format-version 1 --manifest-path "${manifest}" >/dev/null 2>&1; then
      continue
    fi
    echo "🔄 Lockfile out of sync for ${manifest}; reconciling minimally via cargo metadata..."
    if ! cargo metadata --format-version 1 --manifest-path "${manifest}" >/dev/null; then
      echo "ERROR: Failed to reconcile Cargo.lock for ${manifest}." >&2
      return 1
    fi
    cargo metadata --locked --format-version 1 --manifest-path "${manifest}" >/dev/null
    echo "✅ Reconciled lockfile cleanly for ${manifest}."
  done
  return 0
}

format_sync_exhausted_marker() {
  local upstream_sha="$1"
  local state_sha="$2"
  printf '<!-- cua-sync-exhausted: %s:%s -->' "${upstream_sha}" "${state_sha}"
}

should_skip_exhausted_schedule() {
  # Returns 0 (skip) ONLY on scheduled runs when the exact (upstream_sha, state_sha) pair
  # already exhausted automated healing. Manual workflow_dispatch or any SHA change returns 1 (run).
  local event_name="$1"
  local alert_bodies="$2"
  local upstream_sha="$3"
  local state_sha="$4"

  if [[ "${event_name}" != "schedule" ]]; then
    return 1
  fi
  if [[ -z "${upstream_sha}" || -z "${state_sha}" ]]; then
    return 1
  fi

  local marker
  marker=$(format_sync_exhausted_marker "${upstream_sha}" "${state_sha}")
  if grep -Fq -- "${marker}" <<<"${alert_bodies}"; then
    return 0
  fi
  return 1
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
    mkdir -p "${SYNC_BIN_DIR}"
    echo "🔎 Probing live Vertex AI access for gemini-3.8-flash and gemini-4-argon..."
    if ! python3 "${proxy_script}" --probe-vertex \
      --models "gemini-3.8-flash,gemini-4-argon" \
      --write-healthy-order "${SYNC_BIN_DIR}/vertex_healthy_models.txt"; then
      echo "ERROR: Live Vertex AI connectivity/quota probe failed for Argon and 3.8 Flash." >&2
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
  local marker_re='^(<<<<<<<|=======|>>>>>>>|\|\|\|\|\|\|\|)( |$)'
  local cf
  while IFS= read -r cf; do
    if [[ -n "${cf}" && -f "${cf}" ]] && grep -nE "${marker_re}" -- "${cf}" >/dev/null 2>&1; then
      return 0
    fi
  done <<< "${CONFLICT_FILES:-}"

  local scope="${AGY_EDIT_SCOPE:-.}"
  while IFS= read -r cf; do
    if [[ -n "${cf}" && -f "${cf}" ]] && grep -nE "${marker_re}" -- "${cf}" >/dev/null 2>&1; then
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

extract_conflict_context_digest() {
  # Pre-extracts 1-indexed conflict hunks + surrounding helper functions + symmetric non-merge
  # commit logs since merge-base so agy resolves conflicts in 9,000+ line files in 1-2 turns
  # instead of burning 10+ tool-call turns searching for markers.
  local files_input="${1:-${CONFLICT_FILES:-}}"
  CONFLICT_FILES_INPUT="${files_input}" python3 - <<'PY'
import os
import subprocess
from pathlib import Path

raw_files = [
    ln.strip()
    for ln in os.environ.get("CONFLICT_FILES_INPUT", "").splitlines()
    if ln.strip()
]


def git_out(args: list[str]) -> str:
    res = subprocess.run(args, capture_output=True, text=True)
    return res.stdout.strip() if res.returncode == 0 else ""


merge_base = git_out(["git", "merge-base", "HEAD", "MERGE_HEAD"])
has_merge_head = bool(git_out(["git", "rev-parse", "--verify", "--quiet", "MERGE_HEAD"]))

BEFORE_CTX = 125
AFTER_CTX = 45
COALESCE_GAP = 80
MAX_LINES_PER_FILE = 450
MAX_TOTAL_LINES = 950

total_emitted = 0
out_chunks: list[str] = []

for rel in raw_files:
    p = Path(rel)
    if not p.is_file():
        out_chunks.append(f"=== Conflict File: {rel} (missing/deleted in working tree) ===")
        continue

    lines = p.read_text(encoding="utf-8", errors="replace").splitlines()
    n_lines = len(lines)

    regions: list[tuple[int, int]] = []
    cur_start: int | None = None
    for idx, ln in enumerate(lines, 1):
        if ln.startswith("<<<<<<<") and (len(ln) == 7 or ln[7] == " "):
            if cur_start is None:
                cur_start = idx
        elif ln.startswith(">>>>>>>") and (len(ln) == 7 or ln[7] == " "):
            start = cur_start if cur_start is not None else max(1, idx - 20)
            regions.append((start, idx))
            cur_start = None
    if cur_start is not None:
        regions.append((cur_start, min(n_lines, cur_start + 80)))

    if merge_base and has_merge_head:
        theirs_log = git_out(
            ["git", "log", "--no-merges", "--oneline", "-n", "8", f"{merge_base}..MERGE_HEAD", "--", rel]
        )
        ours_log = git_out(
            ["git", "log", "--no-merges", "--oneline", "-n", "8", f"{merge_base}..HEAD", "--", rel]
        )
    else:
        theirs_log = git_out(["git", "log", "--oneline", "-n", "5", "MERGE_HEAD", "--", rel]) if has_merge_head else ""
        ours_log = git_out(["git", "log", "--oneline", "-n", "5", "HEAD", "--", rel])

    header = [
        f"=== Conflict File: {rel} (total {n_lines} lines, {len(regions)} conflict block(s)) ===",
        f"[Upstream MERGE_HEAD commits since merge-base]:\n{theirs_log or '  (none)'}",
        f"[Fork HEAD commits since merge-base]:\n{ours_log or '  (none)'}",
    ]
    out_chunks.append("\n".join(header))

    if not regions or total_emitted >= MAX_TOTAL_LINES:
        continue

    # Expand and coalesce nearby conflict windows so adjacent helpers & hunks appear seamlessly.
    windows: list[list[int]] = []
    for s, e in regions:
        ws = max(1, s - BEFORE_CTX)
        we = min(n_lines, e + AFTER_CTX)
        if windows and ws <= windows[-1][1] + COALESCE_GAP:
            windows[-1][1] = max(windows[-1][1], we)
        else:
            windows.append([ws, we])

    file_emitted = 0
    for ws, we in windows:
        budget = min(MAX_LINES_PER_FILE - file_emitted, MAX_TOTAL_LINES - total_emitted)
        if budget <= 0:
            out_chunks.append(
                f"  ... [digest budget reached; inspect lines {ws}-{we} of {rel} directly if needed] ..."
            )
            break
        span_len = we - ws + 1
        snippet_lines = [f"--- {rel} lines {ws}..{we} (1-indexed) ---"]
        if span_len <= budget:
            for ln_no in range(ws, we + 1):
                snippet_lines.append(f"{ln_no:5d}: {lines[ln_no - 1]}")
            file_emitted += span_len
            total_emitted += span_len
        else:
            half = max(20, budget // 2)
            first_end = ws + half - 1
            second_start = we - (budget - half) + 1
            for ln_no in range(ws, first_end + 1):
                snippet_lines.append(f"{ln_no:5d}: {lines[ln_no - 1]}")
            snippet_lines.append(
                f"  ... [lines {first_end + 1}..{second_start - 1} omitted for brevity; read that exact range if needed] ..."
            )
            for ln_no in range(second_start, we + 1):
                snippet_lines.append(f"{ln_no:5d}: {lines[ln_no - 1]}")
            file_emitted += budget
            total_emitted += budget
        out_chunks.append("\n".join(snippet_lines))

print("\n\n".join(out_chunks))
PY
}

save_agy_workspace_checkpoint() {
  local ckpt_dir="$1"
  local scope="${AGY_EDIT_SCOPE:-.}"
  rm -rf "${ckpt_dir}"
  mkdir -p "${ckpt_dir}/files"

  local git_dir
  git_dir=$(git rev-parse --git-dir 2>/dev/null || echo ".git")
  if [[ -f "${git_dir}/index" ]]; then
    cp -f "${git_dir}/index" "${ckpt_dir}/git_index"
  fi

  local df
  while IFS= read -r df; do
    if [[ -n "${df}" && -f "${df}" ]]; then
      mkdir -p "${ckpt_dir}/files/$(dirname "${df}")"
      cp -f -- "${df}" "${ckpt_dir}/files/${df}"
    fi
  done < <(
    {
      printf '%s\n' "${CONFLICT_FILES:-}"
      git diff --name-only -- "${scope}" 2>/dev/null || true
      git diff --name-only --diff-filter=U 2>/dev/null || true
    } | sort -u
  )

  git ls-files --others --exclude-standard -- "${scope}" > "${ckpt_dir}/pre_untracked.txt" 2>/dev/null || true
}

restore_agy_workspace_checkpoint() {
  local ckpt_dir="$1"
  local scope="${AGY_EDIT_SCOPE:-.}"
  local git_dir
  git_dir=$(git rev-parse --git-dir 2>/dev/null || echo ".git")

  if [[ -f "${ckpt_dir}/git_index" ]]; then
    cp -f "${ckpt_dir}/git_index" "${git_dir}/index"
  fi

  local mf
  while IFS= read -r mf; do
    [[ -z "${mf}" ]] && continue
    if [[ -f "${ckpt_dir}/files/${mf}" ]]; then
      mkdir -p "$(dirname "${mf}")"
      cp -f -- "${ckpt_dir}/files/${mf}" "${mf}"
    else
      git checkout -- "${mf}" 2>/dev/null || true
    fi
  done < <(git diff --name-only -- "${scope}" 2>/dev/null || true)

  local src_file rel
  while IFS= read -r -d '' src_file; do
    rel="${src_file#"${ckpt_dir}/files/"}"
    mkdir -p "$(dirname "${rel}")"
    cp -f -- "${src_file}" "${rel}"
  done < <(find "${ckpt_dir}/files" -type f -print0 2>/dev/null || true)

  local uf
  while IFS= read -r uf; do
    [[ -z "${uf}" ]] && continue
    if ! grep -Fxq -- "${uf}" "${ckpt_dir}/pre_untracked.txt" 2>/dev/null; then
      rm -rf -- "${uf}"
    fi
  done < <(git ls-files --others --exclude-standard -- "${scope}" 2>/dev/null || true)
}

select_agy_candidates_for_tier() {
  # STRICT TWO-MODEL POLICY: ONLY Gemini 4 Argon & Gemini 3.8 Flash.
  # Dynamically promotes the responsive pair model to (1/2) when preflight or an earlier
  # round detected Vertex preview queue timeouts on the other model.
  local tier="${1:-deep}"
  local health_file="${2:-${SYNC_BIN_DIR}/vertex_healthy_models.txt}"
  local argon_ok="true"
  local flash_ok="true"

  if [[ -s "${health_file}" ]]; then
    argon_ok="false"
    flash_ok="false"
    if grep -Fxq "gemini-4-argon" "${health_file}" 2>/dev/null; then
      argon_ok="true"
    fi
    if grep -Fxq "gemini-3.8-flash" "${health_file}" 2>/dev/null; then
      flash_ok="true"
    fi
  fi

  if [[ "${tier}" == "fast" ]]; then
    if [[ "${flash_ok}" == "false" && "${argon_ok}" == "true" ]]; then
      printf '%s\n' "gemini-4-argon-high|14m" "gemini-3.8-flash-high|10m"
    else
      printf '%s\n' "gemini-3.8-flash-high|10m" "gemini-4-argon-high|14m"
    fi
  else
    if [[ "${argon_ok}" == "false" && "${flash_ok}" == "true" ]]; then
      printf '%s\n' "gemini-3.8-flash-high|12m" "gemini-4-argon-high|14m"
    else
      printf '%s\n' "gemini-4-argon-high|14m" "gemini-3.8-flash-high|12m"
    fi
  fi
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

  local ckpt_dir="/tmp/agy_ws_ckpt_$$_${RANDOM}"
  save_agy_workspace_checkpoint "${ckpt_dir}"

  local before_hash
  before_hash=$(workspace_snapshot_hash)

  # STRICT TWO-MODEL POLICY: ONLY Gemini 4 Argon & Gemini 3.8 Flash.
  local health_file="${SYNC_BIN_DIR}/vertex_healthy_models.txt"
  local -a candidates=()
  mapfile -t candidates < <(select_agy_candidates_for_tier "${tier}" "${health_file}")

  local agy_rc=1
  local json_status="ERROR"
  local after_hash=""
  local last_err=""
  local idx=0
  local total="${#candidates[@]}"
  local prev_timed_out="false"
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
        if [[ "${prev_timed_out}" == "true" ]]; then
          mkdir -p "${SYNC_BIN_DIR}"
          printf '%s\n' "${cand_model%-*}" > "${health_file}" 2>/dev/null || true
        fi
        echo "✅ [agy:${cand_model}] Completed edits cleanly."
        rm -rf "${ckpt_dir}"
        set -e
        return 0
      fi
    elif [[ "${agy_rc}" -eq 3 && "${after_hash}" != "${before_hash}" ]] && ! has_remaining_conflict_markers; then
      echo "⚠️ [agy:${cand_model}] Hit print-timeout (${cand_tmo}) after writing clean workspace edits; proceeding to outer deterministic verification..."
      SUMMARY=$(jq -r '.response // "已完成代码修复（外层流水线继续执行格式化与 5 层测试校验）。"' /tmp/agy_stdout.json 2>/dev/null || echo "已完成代码修复。")
      rm -rf "${ckpt_dir}"
      set -e
      return 0
    else
      if [[ "${agy_rc}" -eq 3 ]]; then
        prev_timed_out="true"
      fi
      last_err=$(jq -r '.error // empty' /tmp/agy_stdout.json 2>/dev/null || true)
      if [[ -z "${last_err}" ]]; then
        last_err=$(tail -n 8 /tmp/agy_stderr.log 2>/dev/null | tr '\n' ' ' || echo "exit code ${agy_rc}")
      fi
      echo "⚠️ [agy:${cand_model}] Unsuccessful (exit=${agy_rc}, status=${json_status}): ${last_err:0:260}"
    fi

    if [[ "${idx}" -lt "${total}" ]]; then
      echo "↩️ Restoring clean pre-invocation workspace checkpoint before trying next pair model..."
      restore_agy_workspace_checkpoint "${ckpt_dir}"
      sleep 2
    fi
  done
  rm -rf "${ckpt_dir}"
  set -e

  cat /tmp/agy_stderr.log >&2 || true
  local fail_reason="agy 双模型链（${tier}: Argon + 3.8 Flash）均未完成有效修复（exit ${agy_rc} / ${json_status}）：${last_err}"
  if [[ -n "${on_fail_fn}" ]]; then
    "${on_fail_fn}" "${fail_reason}"
  fi
  return 1
}
