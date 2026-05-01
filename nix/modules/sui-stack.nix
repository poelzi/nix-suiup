{ config, lib, pkgs, suiupPackages, ... }:

# Meta-module: turning services.sui-stack.enable on wires up a fullnode +
# postgres + sui-indexer-alt + jsonrpc reader on the same host with sane
# defaults. Layer the per-service modules instead if you want fine control.

let
  cfg = config.services.sui-stack;
in
{
  options.services.sui-stack = {
    enable = lib.mkEnableOption "Full Sui node stack (fullnode + postgres + indexer + jsonrpc)";

    network = lib.mkOption {
      type = lib.types.enum [ "mainnet" "testnet" "devnet" "local" ];
      default = "mainnet";
      description = "Network shared across the fullnode + indexer.";
    };

    rpcUrl = lib.mkOption {
      type = lib.types.str;
      default = "http://127.0.0.1:9000";
      description = "Internal URL the indexer uses to reach the fullnode RPC.";
    };

    enableWalrusAggregator = lib.mkOption {
      type = lib.types.bool;
      default = false;
    };

    enableWalrusPublisher = lib.mkOption {
      type = lib.types.bool;
      default = false;
    };

    enableSealKeyServer = lib.mkOption {
      type = lib.types.bool;
      default = false;
    };
  };

  config = lib.mkIf cfg.enable {
    services.sui-fullnode = {
      enable = true;
      network = cfg.network;
    };

    services.postgresql-sui.enable = true;

    services.sui-indexer-alt = {
      enable = true;
      rpcUrl = cfg.rpcUrl;
    };

    services.sui-indexer-alt-jsonrpc.enable = true;

    services.walrus-aggregator.enable = lib.mkDefault cfg.enableWalrusAggregator;
    services.walrus-publisher.enable = lib.mkDefault cfg.enableWalrusPublisher;
    services.seal-key-server.enable = lib.mkDefault cfg.enableSealKeyServer;
  };
}
