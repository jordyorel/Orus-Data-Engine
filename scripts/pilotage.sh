#!/usr/bin/env bash

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PYTHON_DIR="$ROOT/python"
VENV="$PYTHON_DIR/.venv"
PYTHON="$VENV/bin/python"
API_DIR="$ROOT/apps/ontology-api"
API_VENV="$API_DIR/.venv"
API_PYTHON="$API_VENV/bin/python"
WEB_DIR="$ROOT/web/ontology-explorer"
CONTROL_DIR="$ROOT/apps/control-plane-api"
CONTROL_VENV="$CONTROL_DIR/.venv"
CONTROL_PYTHON="$CONTROL_VENV/bin/python"
STUDIO_DIR="$ROOT/web/orus-studio"
ENGINE="$ROOT/zig-out/bin/orusdata"
CUSTOMERS_CSV="${CUSTOMERS_CSV:-$ROOT/fixtures/customers-2000000.csv}"
RUN_ID="${RUN_ID:-dca43ce5-0fd8-5cbc-b9d7-8a2527f50fde}"
OBSERVED_AT="${OBSERVED_AT:-2026-08-15T12:00:00+00:00}"
BATCH_SIZE="${BATCH_SIZE:-2048}"
SAMPLE_ROWS="${SAMPLE_ROWS:-10000}"
CHECKPOINT="${CHECKPOINT:-$ROOT/.zig-cache/customers-2m.checkpoint.json}"
PYTHON_BOOTSTRAP="${PYTHON_BOOTSTRAP:-python3}"
POSTGRES_PORT="${POSTGRES_PORT:-55439}"
POSTGRES_DATA="${POSTGRES_DATA:-$ROOT/.zig-cache/orus-postgres}"
POSTGRES_LOG="${POSTGRES_LOG:-$ROOT/.zig-cache/orus-postgres.log}"
POSTGRES_DSN="${POSTGRES_DSN:-host=/tmp port=$POSTGRES_PORT dbname=postgres}"

usage() {
    cat <<'EOF'
Usage: ./scripts/pilotage.sh <command>

Setup and quality:
  setup                 Create the Python environment and install dependencies
  setup-api             Create the API environment and install its dependencies
  setup-web             Install the explorer dependencies
  setup-control         Create the Control Plane environment
  setup-studio          Install Orus Studio dependencies
  build                 Build the Zig CLI in ReleaseFast mode
  test                  Run all tests and static checks (without PostgreSQL)
  test-zig              Run Zig Debug and ReleaseSafe tests
  test-python           Run the Python test suite
  test-api              Run API tests without PostgreSQL integration
  test-api-postgres     Run all API tests against the configured PostgreSQL
  test-web              Run explorer tests
  build-web             Typecheck and build the production explorer
  test-control          Run Control Plane tests
  test-studio           Run Orus Studio tests
  build-studio          Typecheck and build Orus Studio
  check                 Run Zig fmt, Ruff and Pyright

Local PostgreSQL:
  postgres-start        Initialize and start the project-local server
  postgres-status       Check the project-local server and connection
  postgres-stop         Stop the project-local server

Engine and ontology:
  benchmark-csv         Benchmark typed ingestion on the 2M customer CSV
  benchmark-ontology    Benchmark ontology materialization in memory
  import-sample         Import SAMPLE_ROWS rows into PostgreSQL
  import-full           Import all 2M rows, with a resumable checkpoint
  ontology-stats        Display PostgreSQL ontology table cardinalities
  test-postgres-zig     Test the Zig PostgreSQL connector on port 55432
  test-postgres-python  Run Python storage tests against POSTGRES_DSN
  api-dev               Start the API on 127.0.0.1:8080
  web-dev               Start the explorer on 127.0.0.1:5173
  control-dev           Start the Control Plane on 127.0.0.1:8081
  studio-dev            Start Orus Studio on 127.0.0.1:5174

Configuration variables:
  POSTGRES_DSN   Default: host=/tmp port=55439 dbname=postgres
  POSTGRES_PORT  Default: 55439
  POSTGRES_DATA  Default: .zig-cache/orus-postgres
  CUSTOMERS_CSV  Default: fixtures/customers-2000000.csv
  SAMPLE_ROWS    Default: 10000
  BATCH_SIZE     Default: 2048
  CHECKPOINT     Default: .zig-cache/customers-2m.checkpoint.json
  PYTHON_BOOTSTRAP  Python >= 3.12 used to create the environment
  RUN_ID, OBSERVED_AT

Examples:
  POSTGRES_DSN='host=/tmp port=55439 dbname=postgres' \
    ./scripts/pilotage.sh import-sample
  SAMPLE_ROWS=100000 ./scripts/pilotage.sh benchmark-ontology
EOF
}

require_file() {
    [[ -f "$1" ]] || { printf 'Missing file: %s\n' "$1" >&2; exit 1; }
}

require_python() {
    require_file "$PYTHON"
}

require_engine() {
    require_file "$ENGINE"
}

require_api_python() {
    require_file "$API_PYTHON"
}

require_control_python() {
    require_file "$CONTROL_PYTHON"
}

require_postgres() {
    command -v pg_isready >/dev/null || {
        printf 'pg_isready is required; install PostgreSQL first\n' >&2
        exit 1
    }
    if ! pg_isready -d "$POSTGRES_DSN" >/dev/null 2>&1; then
        printf 'PostgreSQL is not reachable with: %s\nRun:\n  %s postgres-start\n' \
            "$POSTGRES_DSN" "$0" >&2
        exit 1
    fi
}

run_vertical() {
    local max_rows="${1:-}"
    local checkpoint="${2:-}"
    local args=(
        -m orus_ontology.vertical "$CUSTOMERS_CSV"
        --postgres "$POSTGRES_DSN"
        --engine "$ENGINE"
        --run-id "$RUN_ID"
        --observed-at "$OBSERVED_AT"
        --batch-size "$BATCH_SIZE"
    )
    [[ -n "$max_rows" ]] && args+=(--max-rows "$max_rows")
    [[ -n "$checkpoint" ]] && args+=(--checkpoint "$checkpoint")
    (cd "$PYTHON_DIR" && "$PYTHON" "${args[@]}")
}

command="${1:-help}"
case "$command" in
    help|-h|--help)
        usage
        ;;
    setup)
        "$PYTHON_BOOTSTRAP" -m venv "$VENV"
        "$PYTHON" -c 'import sys; assert sys.version_info >= (3, 12), "Python >= 3.12 is required"'
        "$VENV/bin/pip" install -e "$PYTHON_DIR[postgres,dev]"
        ;;
    setup-api)
        "$PYTHON_BOOTSTRAP" -m venv "$API_VENV"
        "$API_PYTHON" -c \
            'import sys; assert sys.version_info >= (3, 12), "Python >= 3.12 is required"'
        "$API_VENV/bin/pip" install -e "$PYTHON_DIR[postgres]" -e "$API_DIR[dev]"
        ;;
    setup-web)
        (cd "$WEB_DIR" && npm install)
        ;;
    setup-control)
        "$PYTHON_BOOTSTRAP" -m venv "$CONTROL_VENV"
        "$CONTROL_PYTHON" -c \
            'import sys; assert sys.version_info >= (3, 12), "Python >= 3.12 is required"'
        "$CONTROL_VENV/bin/pip" install -e "$CONTROL_DIR[dev]"
        ;;
    setup-studio)
        (cd "$STUDIO_DIR" && npm install)
        ;;
    build)
        (cd "$ROOT" && zig build -Doptimize=ReleaseFast)
        ;;
    test-zig)
        (cd "$ROOT" && zig build test && zig build -Doptimize=ReleaseSafe test)
        ;;
    test-python)
        require_python
        (cd "$PYTHON_DIR" && "$PYTHON" -m pytest)
        ;;
    test-api)
        require_api_python
        (cd "$API_DIR" && "$API_PYTHON" -m pytest -k 'not postgres_integration')
        ;;
    test-api-postgres)
        require_api_python
        require_postgres
        (cd "$API_DIR" && ORUS_ONTOLOGY_API_TEST_POSTGRES="$POSTGRES_DSN" \
            "$API_PYTHON" -m pytest)
        ;;
    test-web)
        (cd "$WEB_DIR" && npm test)
        ;;
    build-web)
        (cd "$WEB_DIR" && npm run build)
        ;;
    test-control)
        require_control_python
        (cd "$CONTROL_DIR" && "$CONTROL_PYTHON" -m pytest)
        ;;
    test-studio)
        (cd "$STUDIO_DIR" && npm test)
        ;;
    build-studio)
        (cd "$STUDIO_DIR" && npm run build)
        ;;
    check)
        require_python
        require_api_python
        require_control_python
        (cd "$ROOT" && zig fmt --check build.zig src tests benchmarks)
        (cd "$PYTHON_DIR" && "$PYTHON" -m ruff check . && "$PYTHON" -m pyright)
        (cd "$API_DIR" && "$API_PYTHON" -m ruff check . && "$API_PYTHON" -m pyright)
        (cd "$WEB_DIR" && npm run typecheck)
        (cd "$CONTROL_DIR" && "$CONTROL_PYTHON" -m ruff check . && "$CONTROL_PYTHON" -m pyright)
        (cd "$STUDIO_DIR" && npm run typecheck)
        ;;
    postgres-start)
        command -v initdb >/dev/null || { printf 'initdb is required\n' >&2; exit 1; }
        command -v pg_ctl >/dev/null || { printf 'pg_ctl is required\n' >&2; exit 1; }
        mkdir -p "$(dirname "$POSTGRES_DATA")"
        if [[ ! -f "$POSTGRES_DATA/PG_VERSION" ]]; then
            initdb -D "$POSTGRES_DATA" --auth-local=trust --auth-host=scram-sha-256
        fi
        if pg_ctl -D "$POSTGRES_DATA" status >/dev/null 2>&1; then
            printf 'Project PostgreSQL is already running.\n'
        else
            pg_ctl -D "$POSTGRES_DATA" -l "$POSTGRES_LOG" \
                -o "-p $POSTGRES_PORT -k /tmp" start
        fi
        pg_isready -h /tmp -p "$POSTGRES_PORT" -d postgres
        printf 'POSTGRES_DSN=%s\n' "$POSTGRES_DSN"
        ;;
    postgres-status)
        command -v pg_ctl >/dev/null || { printf 'pg_ctl is required\n' >&2; exit 1; }
        pg_ctl -D "$POSTGRES_DATA" status
        pg_isready -h /tmp -p "$POSTGRES_PORT" -d postgres
        ;;
    postgres-stop)
        command -v pg_ctl >/dev/null || { printf 'pg_ctl is required\n' >&2; exit 1; }
        if pg_ctl -D "$POSTGRES_DATA" status >/dev/null 2>&1; then
            pg_ctl -D "$POSTGRES_DATA" stop -m fast
        else
            printf 'Project PostgreSQL is not running.\n'
        fi
        ;;
    test)
        "$0" test-zig
        "$0" test-python
        "$0" test-api
        "$0" test-web
        "$0" test-control
        "$0" test-studio
        "$0" check
        ;;
    benchmark-csv)
        require_engine
        require_file "$CUSTOMERS_CSV"
        "$ENGINE" benchmark "$CUSTOMERS_CSV" "$BATCH_SIZE"
        ;;
    benchmark-ontology)
        require_python
        require_engine
        require_file "$CUSTOMERS_CSV"
        (cd "$PYTHON_DIR" && "$PYTHON" benchmarks/ontology_v1.py \
            --engine "$ENGINE" --csv "$CUSTOMERS_CSV" \
            --rows "$SAMPLE_ROWS" --batch-size "$BATCH_SIZE")
        ;;
    import-sample)
        require_python
        require_engine
        require_file "$CUSTOMERS_CSV"
        require_postgres
        run_vertical "$SAMPLE_ROWS"
        ;;
    import-full)
        require_python
        require_engine
        require_file "$CUSTOMERS_CSV"
        require_postgres
        printf 'Full import may require 33-45 GiB of PostgreSQL disk space.\n'
        df -h "$ROOT"
        run_vertical "" "$CHECKPOINT"
        ;;
    ontology-stats)
        require_postgres
        command -v psql >/dev/null || { printf 'psql is required\n' >&2; exit 1; }
        psql "$POSTGRES_DSN" -v ON_ERROR_STOP=1 -P pager=off -c \
            "SELECT 'objects' AS entity, count(*) FROM orus_ontology_objects
             UNION ALL SELECT 'relations', count(*) FROM orus_ontology_relations
             UNION ALL SELECT 'assertions', count(*) FROM orus_ontology_assertions
             ORDER BY entity;"
        ;;
    test-postgres-zig)
        (cd "$ROOT" && zig build -Dpostgres=true test-postgres)
        ;;
    test-postgres-python)
        require_python
        require_postgres
        (cd "$PYTHON_DIR" && ORUS_ONTOLOGY_TEST_POSTGRES="$POSTGRES_DSN" \
            "$PYTHON" -m pytest tests/storage/test_postgres_persistence.py)
        ;;
    api-dev)
        require_api_python
        require_postgres
        cd "$API_DIR"
        ORUS_ONTOLOGY_API_POSTGRES_DSN="$POSTGRES_DSN" \
            exec "$API_VENV/bin/uvicorn" orus_ontology_api.main:app \
                --host "${ORUS_ONTOLOGY_API_HOST:-127.0.0.1}" \
                --port "${ORUS_ONTOLOGY_API_PORT:-8080}" --reload
        ;;
    web-dev)
        cd "$WEB_DIR"
        exec npm run dev
        ;;
    control-dev)
        require_control_python
        require_engine
        cd "$CONTROL_DIR"
        ORUS_CONTROL_ENGINE="$ENGINE" \
            exec "$CONTROL_VENV/bin/uvicorn" orus_control_plane_api.main:app \
                --host "${ORUS_CONTROL_HOST:-127.0.0.1}" \
                --port "${ORUS_CONTROL_PORT:-8081}" --reload
        ;;
    studio-dev)
        cd "$STUDIO_DIR"
        exec npm run dev
        ;;
    *)
        printf 'Unknown command: %s\n\n' "$command" >&2
        usage >&2
        exit 2
        ;;
esac
