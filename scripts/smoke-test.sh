#!/usr/bin/env bash
set -euo pipefail

# Runs the netns lab with and without flow offload to ensure mitigation keeps PBR/NAT flows offloaded safely.

ROOT_DIR=$(cd "$(dirname "$0")/.." && pwd)
LAB="${ROOT_DIR}/reproducer/netns-lab.sh"
LOG_DIR="${ROOT_DIR}/reproducer/output"

mkdir -p "${LOG_DIR}"

run_case() {
  local name="$1"; shift
  echo "[smoke] running case: ${name}" >&2
  CLEAN_LOGS=0 LOG_DIR="${LOG_DIR}" "$LAB" run "$@" | tee "${LOG_DIR}/smoke-${name}.log"
  if grep -q "MAC delivery MISMATCH" "${LOG_DIR}/smoke-${name}.log"; then
    echo "[smoke] FAIL: MAC mismatch detected in ${name}" >&2
    exit 1
  fi
  echo "[smoke] case ${name} passed" >&2
}

run_case "offload-off" FLOW_OFFLOAD=0 MITIGATION=1 USE_PBR_MARK=1
run_case "offload-on-mitigated" FLOW_OFFLOAD=1 MITIGATION=1 USE_PBR_MARK=1

echo "[smoke] all cases passed"
