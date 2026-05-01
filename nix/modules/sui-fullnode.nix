{ config, lib, pkgs, suiupPackages, ... }:

let
  cfg = config.services.sui-fullnode;
in
{
  options.services.sui-fullnode = {
    enable = lib.mkEnableOption "Sui fullnode (sui-node)";

    package = lib.mkOption {
      type = lib.types.package;
      default = suiupPackages.sui-node;
      defaultText = lib.literalExpression "suiupPackages.sui-node";
      description = "sui-node package to run.";
    };

    network = lib.mkOption {
      type = lib.types.enum [ "mainnet" "testnet" "devnet" "local" ];
      default = "mainnet";
      description = "Which Sui network this fullnode joins.";
    };

    dataDir = lib.mkOption {
      type = lib.types.path;
      default = "/var/lib/sui-fullnode";
      description = "Location for the fullnode database / config.";
    };

    rpcPort = lib.mkOption {
      type = lib.types.port;
      default = 9000;
      description = "JSON-RPC port.";
    };

    metricsPort = lib.mkOption {
      type = lib.types.port;
      default = 9184;
      description = "Prometheus metrics port.";
    };

    extraArgs = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "Extra CLI flags appended to sui-node.";
    };

    user = lib.mkOption {
      type = lib.types.str;
      default = "sui-fullnode";
    };

    group = lib.mkOption {
      type = lib.types.str;
      default = "sui-fullnode";
    };

    openFirewall = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Open RPC + p2p ports in the host firewall.";
    };

    configFile = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      description = ''
        Path to fullnode.yaml. If unset, the unit assumes
        $dataDir/fullnode.yaml exists at startup.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    users.users.${cfg.user} = {
      isSystemUser = true;
      group = cfg.group;
      home = cfg.dataDir;
      createHome = true;
    };
    users.groups.${cfg.group} = { };

    networking.firewall = lib.mkIf cfg.openFirewall {
      allowedTCPPorts = [ cfg.rpcPort 8080 ];
    };

    systemd.services.sui-fullnode = {
      description = "Sui fullnode (${cfg.network})";
      wantedBy = [ "multi-user.target" ];
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];

      serviceConfig = {
        Type = "exec";
        User = cfg.user;
        Group = cfg.group;
        WorkingDirectory = cfg.dataDir;
        StateDirectory = "sui-fullnode";
        ExecStart = lib.escapeShellArgs (
          [ "${cfg.package}/bin/sui-node" "--config-path" (
              if cfg.configFile != null then cfg.configFile else "${cfg.dataDir}/fullnode.yaml"
            ) ] ++ cfg.extraArgs
        );
        Restart = "on-failure";
        RestartSec = "10s";
        LimitNOFILE = 1048576;
      };
    };
  };
}
