{ config, lib, pkgs, suiupPackages, ... }:

let
  cfg = config.services.walrus-publisher;
in
{
  options.services.walrus-publisher = {
    enable = lib.mkEnableOption "walrus publisher (write-side gateway, holds a Sui keypair)";

    package = lib.mkOption {
      type = lib.types.package;
      default = suiupPackages.walrus;
      defaultText = lib.literalExpression "suiupPackages.walrus";
    };

    listenAddress = lib.mkOption {
      type = lib.types.str;
      default = "0.0.0.0:31416";
    };

    walrusConfig = lib.mkOption {
      type = lib.types.path;
      description = "Path to client_config.yaml (network info, package id).";
    };

    suiKeyfile = lib.mkOption {
      type = lib.types.path;
      description = "Sui keystore file used for write transactions. Pass via secrets — not world-readable.";
    };

    extraArgs = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
    };
  };

  config = lib.mkIf cfg.enable {
    users.users.walrus-publisher = {
      isSystemUser = true;
      group = "walrus-publisher";
    };
    users.groups.walrus-publisher = { };

    systemd.services.walrus-publisher = {
      description = "Walrus publisher (write-side HTTP gateway)";
      wantedBy = [ "multi-user.target" ];
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];

      serviceConfig = {
        Type = "exec";
        User = "walrus-publisher";
        Group = "walrus-publisher";
        LoadCredential = [ "sui-keyfile:${toString cfg.suiKeyfile}" ];
        ExecStart = lib.escapeShellArgs (
          [
            "${cfg.package}/bin/walrus"
            "--config" (toString cfg.walrusConfig)
            "publisher"
            "--bind-address" cfg.listenAddress
            "--keystore-path" "%d/sui-keyfile"
          ] ++ cfg.extraArgs
        );
        Restart = "on-failure";
        RestartSec = "10s";
      };
    };
  };
}
