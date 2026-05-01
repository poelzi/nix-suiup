#!/usr/bin/env bash
# Local sui dev / test environment.
#
# Boots:
#   * a private PostgreSQL cluster in a state dir
#   * `sui start` with --with-faucet, --with-indexer, --with-graphql
#
# Endpoints printed at startup; press Ctrl+C to stop everything cleanly.

set -euo pipefail

STATE_DIR="${SUIUP_TEST_ENV_DIR:-}"
if [ -z "$STATE_DIR" ]; then
  STATE_DIR="$(mktemp -d --tmpdir suiup-test-env.XXXXXX)"
  CLEANUP_STATE=1
else
  mkdir -p "$STATE_DIR"
  CLEANUP_STATE=0
fi

PGDATA="$STATE_DIR/pg"
SUI_CONFIG="$STATE_DIR/sui-config"
LOG_DIR="$STATE_DIR/logs"
mkdir -p "$LOG_DIR"

PG_PORT="${SUIUP_TEST_PG_PORT:-15432}"
RPC_PORT="${SUIUP_TEST_RPC_PORT:-9000}"
FAUCET_PORT="${SUIUP_TEST_FAUCET_PORT:-9123}"
INDEXER_DB="sui_indexer"
INDEXER_USER="$(id -un)"

DATABASE_URL="postgres://${INDEXER_USER}@127.0.0.1:${PG_PORT}/${INDEXER_DB}"

cleanup() {
  set +e
  echo
  echo "[test-env] shutting down..."
  if [ -n "${SUI_PID:-}" ]; then kill -TERM "$SUI_PID" 2>/dev/null; fi
  if [ -n "${SUI_PID:-}" ]; then wait "$SUI_PID" 2>/dev/null; fi
  if [ -d "$PGDATA" ]; then pg_ctl -D "$PGDATA" -m fast stop >/dev/null 2>&1 || true; fi
  if [ "$CLEANUP_STATE" = 1 ]; then
    echo "[test-env] removing $STATE_DIR"
    rm -rf "$STATE_DIR"
  else
    echo "[test-env] state preserved at $STATE_DIR"
  fi
}
trap cleanup EXIT INT TERM

# --- PostgreSQL bring-up ---
if [ ! -s "$PGDATA/PG_VERSION" ]; then
  echo "[test-env] initdb $PGDATA"
  initdb -D "$PGDATA" -U "$INDEXER_USER" --auth=trust --no-locale --encoding=UTF8 >"$LOG_DIR/initdb.log" 2>&1
fi

cat > "$PGDATA/postgresql.conf.suiup" <<EOF
listen_addresses = '127.0.0.1'
port = ${PG_PORT}
unix_socket_directories = '${PGDATA}'
fsync = off
synchronous_commit = off
full_page_writes = off
EOF
# Always layer our overrides on top of the default conf.
sed -i '/^include = .\/postgresql.conf.suiup./d' "$PGDATA/postgresql.conf"
echo "include = './postgresql.conf.suiup'" >> "$PGDATA/postgresql.conf"

echo "[test-env] starting postgres on :${PG_PORT}"
pg_ctl -D "$PGDATA" -l "$LOG_DIR/postgres.log" -w start

# Ensure database exists
psql -h 127.0.0.1 -p "$PG_PORT" -U "$INDEXER_USER" -d postgres -tAc \
  "SELECT 1 FROM pg_database WHERE datname='${INDEXER_DB}'" | grep -q 1 \
  || createdb -h 127.0.0.1 -p "$PG_PORT" -U "$INDEXER_USER" "$INDEXER_DB"

# --- sui start with everything attached ---
mkdir -p "$SUI_CONFIG"

cat <<EOF

================================================================
suiup test environment
----------------------------------------------------------------
state dir       : $STATE_DIR
sui config      : $SUI_CONFIG
postgres        : 127.0.0.1:${PG_PORT}/${INDEXER_DB}
DATABASE_URL    : $DATABASE_URL
sui RPC URL     : http://127.0.0.1:${RPC_PORT}
sui faucet URL  : http://127.0.0.1:${FAUCET_PORT}/gas
indexer JSON-RPC: http://127.0.0.1:9124
sui graphql     : http://127.0.0.1:9125
----------------------------------------------------------------
Export these for downstream tests:
  export SUI_RPC_URL=http://127.0.0.1:${RPC_PORT}
  export SUI_FAUCET_URL=http://127.0.0.1:${FAUCET_PORT}/gas
  export DATABASE_URL=$DATABASE_URL
================================================================

EOF

sui start \
  --force-regenesis \
  --with-faucet="0.0.0.0:${FAUCET_PORT}" \
  --with-indexer="${DATABASE_URL}" \
  --with-graphql \
  --fullnode-rpc-port "$RPC_PORT" \
  --network.config "$SUI_CONFIG" &
SUI_PID=$!

wait "$SUI_PID"
