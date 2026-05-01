{ config, lib, pkgs, suiupPackages, ... }:

let
  cfg = config.services.sui-indexer-alt-jsonrpc;
in
{
  options.services.sui-indexer-alt-jsonrpc = {
    enable = lib.mkEnableOption "sui-indexer-alt-jsonrpc (JSON-RPC reader on top of the indexer DB)";

    package = lib.mkOption {
      type = lib.types.package;
      default = suiupPackages.sui-indexer-alt-jsonrpc;
      defaultText = lib.literalExpression "suiupPackages.sui-indexer-alt-jsonrpc";
    };

    databaseUrl = lib.mkOption {
      type = lib.types.str;
      default = "postgres://sui_indexer@127.0.0.1:5432/sui_indexer";
    };

    listenAddress = lib.mkOption {
      type = lib.types.str;
      default = "0.0.0.0:6000";
      description = "host:port the JSON-RPC service binds to.";
    };

    extraArgs = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
    };
  };

  config = lib.mkIf cfg.enable {
    users.users.sui-indexer-jsonrpc = {
      isSystemUser = true;
      group = "sui-indexer-jsonrpc";
    };
    users.groups.sui-indexer-jsonrpc = { };

    systemd.services.sui-indexer-alt-jsonrpc = {
      description = "sui-indexer-alt-jsonrpc";
      wantedBy = [ "multi-user.target" ];
      after = [ "network-online.target" "sui-indexer-alt.service" "postgresql.service" ];
      wants = [ "sui-indexer-alt.service" ];

      serviceConfig = {
        Type = "exec";
        User = "sui-indexer-jsonrpc";
        Group = "sui-indexer-jsonrpc";
        ExecStart = lib.escapeShellArgs (
          [
            "${cfg.package}/bin/sui-indexer-alt-jsonrpc"
            "--database-url" cfg.databaseUrl
            "--listen-address" cfg.listenAddress
          ] ++ cfg.extraArgs
        );
        Restart = "on-failure";
        RestartSec = "10s";
      };
    };
  };
}
