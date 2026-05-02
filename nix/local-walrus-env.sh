#!/usr/bin/env bash
set -euo pipefail

cluster_dir="${SUIUP_LOCAL_WALRUS_DIR:-$PWD/.suiup-local-walrus}"
contracts_src="${SUIUP_WALRUS_CONTRACTS:-}"
walrus_http_bind="${SUIUP_WALRUS_HTTP_BIND:-127.0.0.1:31415}"
walrus_metrics_bind="${SUIUP_WALRUS_METRICS_BIND:-127.0.0.1:31416}"
n_walrus_nodes="${SUIUP_WALRUS_LOCAL_NODES:-4}"
n_walrus_shards="${SUIUP_WALRUS_LOCAL_SHARDS:-10}"

state_dir="$cluster_dir/state"
sui_state="$state_dir/sui"
walrus_state="$state_dir/walrus"
home_dir="$cluster_dir/home"
env_file="$cluster_dir/cluster.env"

usage() {
  cat <<EOF
Usage: $0 <up|down|status|env|clean|smoke>

Commands:
  up      Start a fresh local Sui + Walrus test environment
  down    Stop running services but keep state
  status  Show current environment status
  env     Print shell exports for downstream tests
  clean   Stop services and remove state
  smoke   Start a fresh environment and verify HTTP PUT/GET blob round-trip
EOF
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "missing required command: $1" >&2
    exit 1
  }
}

discover_contracts() {
  if [[ -n "$contracts_src" ]]; then
    return
  fi

  for candidate in \
    "$PWD/../walrus/contracts" \
    "$PWD/../../walrus/contracts" \
    "/home/poelzi/Projects/hive/walrus/contracts"; do
    if [[ -d "$candidate" ]]; then
      contracts_src="$candidate"
      return
    fi
  done

  for candidate in /home/poelzi/.cargo/git/checkouts/walrus-*/*/contracts; do
    if [[ -d "$candidate" ]]; then
      contracts_src="$candidate"
      return
    fi
  done
}

kill_pid_file() {
  local pid_file="$1"
  [[ -f "$pid_file" ]] || return 0
  local pid
  pid="$(<"$pid_file")"
  if [[ -n "$pid" ]] && kill -0 "$pid" >/dev/null 2>&1; then
    kill "$pid" >/dev/null 2>&1 || true
    wait "$pid" >/dev/null 2>&1 || true
  fi
  rm -f "$pid_file"
}

wait_for_localnet() {
  local client_config="$sui_state/client.yaml"
  local attempts=0
  until sui client --client.config "$client_config" chain-identifier >/dev/null 2>&1; do
    attempts=$((attempts + 1))
    if [[ "$attempts" -ge 180 ]]; then
      echo "Sui localnet did not become ready" >&2
      tail -40 "$state_dir/sui-start.log" >&2 || true
      return 1
    fi
    sleep 2
  done
}

wait_for_http() {
  local url="$1"
  local attempts=0
  until curl -sS -o /dev/null "$url" >/dev/null 2>&1; do
    attempts=$((attempts + 1))
    if [[ "$attempts" -ge 120 ]]; then
      echo "HTTP service not ready: $url" >&2
      return 1
    fi
    sleep 1
  done
}

down_cluster() {
  kill_pid_file "$state_dir/walrus-daemon.pid"
  for pid_file in "$state_dir"/walrus-node-*.pid; do
    kill_pid_file "$pid_file"
  done
  kill_pid_file "$state_dir/sui.pid"
}

write_env_file() {
  local walrus_http_url="http://$walrus_http_bind"
  cat >"$env_file" <<EOF
export SUIUP_LOCAL_WALRUS_DIR="$cluster_dir"
export HOME="$home_dir"
export SUI_CLIENT_CONFIG="$sui_state/client.yaml"
export SUI_RPC_URL="http://127.0.0.1:9000"
export SUI_FAUCET_URL="http://127.0.0.1:9123/gas"
export WALRUS_CONFIG="$home_dir/.config/walrus/client_config.yaml"
export WALRUS_AGGREGATOR_URL="$walrus_http_url"
export WALRUS_PUBLISHER_URL="$walrus_http_url"
export WALRUS_NATIVE_CONFIG="$home_dir/.config/walrus/client_config.yaml"
export SUIUP_LOCAL_WALRUS_TESTS="1"
export SUIUP_LOCAL_WALRUS_SUI_PID="$(<"$state_dir/sui.pid")"
export SUIUP_LOCAL_WALRUS_DAEMON_PID="$(<"$state_dir/walrus-daemon.pid")"
EOF
}

up_cluster() {
  require_cmd sui
  require_cmd walrus
  require_cmd walrus-deploy
  require_cmd walrus-node
  require_cmd curl
  require_cmd jq
  require_cmd awk
  require_cmd grep
  require_cmd sed
  require_cmd find

  discover_contracts
  [[ -n "$contracts_src" && -d "$contracts_src" ]] || {
    echo "unable to find Walrus contracts; set SUIUP_WALRUS_CONTRACTS" >&2
    exit 1
  }

  down_cluster
  rm -rf "$cluster_dir"
  mkdir -p "$state_dir" "$home_dir"

  sui genesis --working-dir "$sui_state" -f --with-faucet --quiet
  sui start --network.config "$sui_state" --with-faucet --quiet >"$state_dir/sui-start.log" 2>&1 &
  echo $! >"$state_dir/sui.pid"
  wait_for_localnet

  sui client --client.config "$sui_state/client.yaml" faucet --url http://localhost:9123/gas >/dev/null 2>&1 || \
    sui client --client.config "$sui_state/client.yaml" faucet >/dev/null 2>&1 || true
  sleep 2

  local walrus_contracts_dir="$state_dir/walrus-contracts"
  cp -R "$contracts_src" "$walrus_contracts_dir"
  chmod -R u+w "$walrus_contracts_dir"
  find "$walrus_contracts_dir" -name build -type d -exec rm -rf {} + 2>/dev/null || true
  find "$walrus_contracts_dir" -name Move.lock -delete 2>/dev/null || true
  find "$walrus_contracts_dir" -name Published.toml -delete 2>/dev/null || true
  find "$walrus_contracts_dir" -name 'Pub.*.toml' -delete 2>/dev/null || true
  while IFS= read -r toml; do
    sed -i '/^\[environments\]/,/^$/d' "$toml"
  done < <(find "$walrus_contracts_dir" -name Move.toml)

  local deploy_out="$state_dir/walrus-deploy.out"
  local host_addresses=()
  for ((i = 0; i < n_walrus_nodes; i++)); do
    host_addresses+=("127.0.0.1")
  done
  walrus-deploy deploy-system-contract \
    --working-dir "$walrus_state" \
    --contract-dir "$walrus_contracts_dir" \
    --do-not-copy-contracts \
    --sui-network "http://localhost:9000;http://localhost:9123/gas" \
    --n-shards "$n_walrus_shards" \
    --host-addresses "${host_addresses[@]}" \
    --storage-price 5 \
    --write-price 1 \
    --epoch-duration 1h \
    --with-wal-exchange 2>&1 | tee "$deploy_out"
  walrus-deploy generate-dry-run-configs --working-dir "$walrus_state" 2>&1 | tee -a "$deploy_out"

  local system_object staking_object exchange_object
  system_object="$(grep 'system_object' "$deploy_out" | awk -F': ' '{print $2}' | head -1)"
  staking_object="$(grep 'staking_object' "$deploy_out" | awk -F': ' '{print $2}' | head -1)"
  exchange_object="$(grep 'exchange_object' "$deploy_out" | awk -F': ' '{print $2}' | head -1)"
  if [[ -z "$system_object" || -z "$staking_object" ]]; then
    echo "failed to extract Walrus system object IDs" >&2
    exit 1
  fi

  for ((i = 0; i < n_walrus_nodes; i++)); do
    local node_config="$walrus_state/dryrun-node-${i}.yaml"
    walrus-node run --config-path "$node_config" --cleanup-storage >"$state_dir/walrus-node-${i}.log" 2>&1 &
    echo $! >"$state_dir/walrus-node-${i}.pid"
  done
  sleep 10

  mkdir -p "$home_dir/.config/walrus" "$home_dir/.sui/sui_config"
  cp "$sui_state/client.yaml" "$home_dir/.sui/sui_config/client.yaml"
  cp "$sui_state/sui.keystore" "$home_dir/.sui/sui_config/sui.keystore"

  local walrus_client_config="$home_dir/.config/walrus/client_config.yaml"
  cat >"$walrus_client_config" <<EOF
system_object: ${system_object}
staking_object: ${staking_object}
wallet_config: ${sui_state}/client.yaml
rpc_urls:
  - http://127.0.0.1:9000
EOF
  if [[ -n "$exchange_object" ]]; then
    cat >>"$walrus_client_config" <<EOF
exchange_objects:
  - ${exchange_object}
EOF
  fi

  HOME="$home_dir" sui client faucet >/dev/null 2>&1 || true
  sleep 2
  HOME="$home_dir" walrus --config "$walrus_client_config" get-wal --amount 500000000000 || true

  mkdir -p "$state_dir/walrus-sub-wallets"
  HOME="$home_dir" walrus --config "$walrus_client_config" daemon \
    --bind-address "$walrus_http_bind" \
    --metrics-address "$walrus_metrics_bind" \
    --sub-wallets-dir "$state_dir/walrus-sub-wallets" \
    >"$state_dir/walrus-daemon.log" 2>&1 &
  echo $! >"$state_dir/walrus-daemon.pid"
  wait_for_http "http://$walrus_http_bind/v1/api"

  write_env_file
  echo "Local Sui + Walrus environment is up. Source env with: source $env_file"
}

status_cluster() {
  if [[ -f "$env_file" ]]; then
    echo "env: $env_file"
    cat "$env_file"
  else
    echo "cluster env not found: $env_file"
  fi
  for pid_file in "$state_dir/sui.pid" "$state_dir/walrus-daemon.pid" "$state_dir"/walrus-node-*.pid; do
    [[ -f "$pid_file" ]] || continue
    local pid
    pid="$(<"$pid_file")"
    if kill -0 "$pid" >/dev/null 2>&1; then
      echo "running: $(basename "$pid_file") -> $pid"
    else
      echo "stopped: $(basename "$pid_file") -> $pid"
    fi
  done
}

clean_cluster() {
  down_cluster
  rm -rf "$cluster_dir"
}

smoke_cluster() {
  up_cluster

  local payload_file read_file response_file blob_id
  payload_file="$state_dir/smoke-payload.bin"
  read_file="$state_dir/smoke-read.bin"
  response_file="$state_dir/smoke-store-response.json"
  printf 'suiup local walrus smoke %s\n' "$(date +%s%N)" >"$payload_file"

  curl -sSf -X PUT "http://$walrus_http_bind/v1/blobs?epochs=1" \
    -H 'Content-Type: application/octet-stream' \
    --upload-file "$payload_file" \
    -o "$response_file"
  blob_id="$(jq -r '.. | objects | .blobId? // empty' "$response_file" | head -1)"
  if [[ -z "$blob_id" || "$blob_id" == "null" ]]; then
    echo "failed to parse blobId from store response" >&2
    cat "$response_file" >&2
    exit 1
  fi

  for _ in $(seq 1 30); do
    if curl -sSf "http://$walrus_http_bind/v1/blobs/$blob_id" -o "$read_file"; then
      break
    fi
    sleep 1
  done
  cmp "$payload_file" "$read_file"
  echo "Walrus HTTP smoke passed: $blob_id"
}

case "${1:-}" in
  up) up_cluster ;;
  down) down_cluster ;;
  status) status_cluster ;;
  env) [[ -f "$env_file" ]] && cat "$env_file" || { echo "cluster env not found: $env_file" >&2; exit 1; } ;;
  clean) clean_cluster ;;
  smoke) smoke_cluster ;;
  *) usage; exit 1 ;;
esac
