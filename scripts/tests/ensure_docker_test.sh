#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENSURE_DOCKER="${SCRIPT_DIR}/../ensure_docker.sh"
TEST_TMP="$(mktemp -d)"
MOCK_BIN="${TEST_TMP}/bin"
mkdir -p "$MOCK_BIN"
trap 'rm -rf "$TEST_TMP"' EXIT

cat > "${MOCK_BIN}/docker" <<'EOF'
#!/bin/bash
set -u

if [[ "$1" == "info" && "${2:-}" == "--format" ]]; then
    if [[ -f "$MOCK_CONFIGURED_FLAG" ]]; then
        printf '%b' "$MOCK_DOCKER_FORMAT_AFTER"
    else
        printf '%b' "$MOCK_DOCKER_FORMAT_BEFORE"
    fi
    exit "$MOCK_DOCKER_FORMAT_STATUS"
fi

if [[ "$1" == "info" ]]; then
    if [[ -f "$MOCK_CONFIGURED_FLAG" ]]; then
        printf '%b' "$MOCK_DOCKER_INFO_AFTER"
    else
        printf '%b' "$MOCK_DOCKER_INFO_BEFORE"
    fi
    exit 0
fi

if [[ "$1" == "ps" ]]; then
    exit 0
fi

exit 0
EOF

cat > "${MOCK_BIN}/nvidia-ctk" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "$MOCK_NVIDIA_CTK_LOG"
touch "$MOCK_CONFIGURED_FLAG"
EOF

cat > "${MOCK_BIN}/sudo" <<'EOF'
#!/bin/bash
exec "$@"
EOF

cat > "${MOCK_BIN}/systemctl" <<'EOF'
#!/bin/bash
exit 0
EOF

cat > "${MOCK_BIN}/id" <<'EOF'
#!/bin/bash
if [[ "${1:-}" == "-u" ]]; then
    printf '0\n'
    exit 0
fi
exec /usr/bin/id "$@"
EOF

cat > "${MOCK_BIN}/uname" <<'EOF'
#!/bin/bash
printf 'x86_64\n'
EOF

cat > "${MOCK_BIN}/tput" <<'EOF'
#!/bin/bash
exit 0
EOF

chmod +x "${MOCK_BIN}/"*

tests_run=0

run_case() {
    local name="$1"
    local format_before="$2"
    local format_status="$3"
    local info_before="$4"
    local format_after="$5"
    local info_after="$6"
    local expected_configures="$7"
    local case_dir="${TEST_TMP}/${tests_run}"
    local output=""
    local actual_configures=0

    mkdir -p "$case_dir"
    tests_run=$((tests_run + 1))

    if ! output="$(
        export PATH="${MOCK_BIN}:/usr/bin:/bin"
        export ZEPHYR_DOCKER_READY=0
        export ZEPHYR_DOCKER_REQUIRE_NVIDIA=1
        export MOCK_CONFIGURED_FLAG="${case_dir}/configured"
        export MOCK_NVIDIA_CTK_LOG="${case_dir}/nvidia-ctk.log"
        export MOCK_DOCKER_FORMAT_BEFORE="$format_before"
        export MOCK_DOCKER_FORMAT_STATUS="$format_status"
        export MOCK_DOCKER_INFO_BEFORE="$info_before"
        export MOCK_DOCKER_FORMAT_AFTER="$format_after"
        export MOCK_DOCKER_INFO_AFTER="$info_after"
        bash "$ENSURE_DOCKER"
    2>&1)"; then
        printf 'not ok - %s\n%s\n' "$name" "$output"
        return 1
    fi

    if [[ -f "${case_dir}/nvidia-ctk.log" ]]; then
        actual_configures="$(wc -l < "${case_dir}/nvidia-ctk.log")"
    fi

    if [[ "$actual_configures" -ne "$expected_configures" ]]; then
        printf 'not ok - %s (expected %s configure call(s), got %s)\n' \
            "$name" "$expected_configures" "$actual_configures"
        return 1
    fi

    printf 'ok - %s\n' "$name"
}

run_case \
    "structured runtime list detects exact nvidia runtime" \
    'runc\nnvidia\n' \
    0 \
    'Runtimes: runc\n cdi: nvidia.com/gpu=all\n' \
    'runc\nnvidia\n' \
    'Runtimes: runc nvidia\n' \
    0

run_case \
    "CDI entries do not masquerade as a runtime" \
    'runc\n' \
    0 \
    'Runtimes: runc\n cdi: nvidia.com/gpu=0\n cdi: nvidia.com/gpu=all\n' \
    'runc\nnvidia\n' \
    'Runtimes: runc nvidia\n' \
    1

run_case \
    "human-readable runtime list is used as a compatibility fallback" \
    '' \
    1 \
    'Runtimes: io.containerd.runc.v2 nvidia runc\n' \
    '' \
    'Runtimes: io.containerd.runc.v2 nvidia runc\n' \
    0

run_case \
    "fallback runtime parsing ignores CDI entries" \
    '' \
    1 \
    'Runtimes: runc\n cdi: nvidia.com/gpu=all\n' \
    '' \
    'Runtimes: runc nvidia\n cdi: nvidia.com/gpu=all\n' \
    1

run_case \
    "runtime names require an exact match" \
    'nvidia-container-runtime\nrunc\n' \
    0 \
    'Runtimes: nvidia-container-runtime runc\n' \
    'nvidia\nnvidia-container-runtime\nrunc\n' \
    'Runtimes: nvidia nvidia-container-runtime runc\n' \
    1

printf '%s tests passed\n' "$tests_run"
