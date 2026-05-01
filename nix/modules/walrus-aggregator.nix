{ config, lib, pkgs, suiupPackages, ... }:

let
  cfg = config.services.walrus-aggregator;
in
{
  options.services.walrus-aggregator = {
    enable = lib.mkEnableOption "walrus aggregator (read-side gateway, no key material)";

    package = lib.mkOption {
      type = lib.types.package;
      default = suiupPackages.walrus;
      defaultText = lib.literalExpression "suiupPackages.walrus";
      description = "Walrus CLI package — invoked as `walrus aggregator`.";
    };

    listenAddress = lib.mkOption {
      type = lib.types.str;
      default = "0.0.0.0:31415";
      description = "Where the HTTP aggregator listens.";
    };

    walrusConfig = lib.mkOption {
      type = lib.types.path;
      description = "Path to client_config.yaml (network info, package id).";
    };

    extraArgs = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
    };
  };

  config = lib.mkIf cfg.enable {
    users.users.walrus-aggregator = {
      isSystemUser = true;
      group = "walrus-aggregator";
    };
    users.groups.walrus-aggregator = { };

    systemd.services.walrus-aggregator = {
      description = "Walrus aggregator (read-side HTTP gateway)";
      wantedBy = [ "multi-user.target" ];
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];

      serviceConfig = {
        Type = "exec";
        User = "walrus-aggregator";
        Group = "walrus-aggregator";
        ExecStart = lib.escapeShellArgs (
          [
            "${cfg.package}/bin/walrus"
            "--config" (toString cfg.walrusConfig)
            "aggregator"
            "--bind-address" cfg.listenAddress
          ] ++ cfg.extraArgs
        );
        Restart = "on-failure";
        RestartSec = "10s";
      };
    };
  };
}
