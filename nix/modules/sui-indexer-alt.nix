{ config, lib, pkgs, suiupPackages, ... }:

let
  cfg = config.services.sui-indexer-alt;
in
{
  options.services.sui-indexer-alt = {
    enable = lib.mkEnableOption "sui-indexer-alt (writes Sui chain state into PostgreSQL)";

    package = lib.mkOption {
      type = lib.types.package;
      default = suiupPackages.sui-indexer-alt;
      defaultText = lib.literalExpression "suiupPackages.sui-indexer-alt";
    };

    rpcUrl = lib.mkOption {
      type = lib.types.str;
      example = "http://127.0.0.1:9000";
      description = "Sui fullnode JSON-RPC URL the indexer reads checkpoints from.";
    };

    databaseUrl = lib.mkOption {
      type = lib.types.str;
      default = "postgres://sui_indexer@127.0.0.1:5432/sui_indexer";
      description = "PostgreSQL DSN.";
    };

    metricsPort = lib.mkOption {
      type = lib.types.port;
      default = 9185;
    };

    extraArgs = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "Additional flags forwarded to sui-indexer-alt.";
    };

    user = lib.mkOption {
      type = lib.types.str;
      default = "sui-indexer";
    };

    group = lib.mkOption {
      type = lib.types.str;
      default = "sui-indexer";
    };
  };

  config = lib.mkIf cfg.enable {
    users.users.${cfg.user} = {
      isSystemUser = true;
      group = cfg.group;
    };
    users.groups.${cfg.group} = { };

    systemd.services.sui-indexer-alt = {
      description = "sui-indexer-alt";
      wantedBy = [ "multi-user.target" ];
      after = [ "network-online.target" "postgresql.service" ];
      wants = [ "network-online.target" "postgresql.service" ];

      environment = {
        DATABASE_URL = cfg.databaseUrl;
      };

      serviceConfig = {
        Type = "exec";
        User = cfg.user;
        Group = cfg.group;
        ExecStart = lib.escapeShellArgs (
          [
            "${cfg.package}/bin/sui-indexer-alt"
            "--remote-store-url" cfg.rpcUrl
            "--metrics-address" "0.0.0.0:${toString cfg.metricsPort}"
            "indexer"
            "--database-url" cfg.databaseUrl
          ] ++ cfg.extraArgs
        );
        Restart = "on-failure";
        RestartSec = "10s";
      };
    };
  };
}
