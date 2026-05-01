{ config, lib, pkgs, suiupPackages, ... }:

let
  cfg = config.services.seal-key-server;
in
{
  options.services.seal-key-server = {
    enable = lib.mkEnableOption "Seal key-server (IBE / threshold decryption service)";

    package = lib.mkOption {
      type = lib.types.package;
      default = suiupPackages.seal-server;
      defaultText = lib.literalExpression "suiupPackages.seal-server";
    };

    listenAddress = lib.mkOption {
      type = lib.types.str;
      default = "0.0.0.0:2024";
    };

    configFile = lib.mkOption {
      type = lib.types.path;
      description = "key-server.yaml — sui RPC URL, master key handle, allowlist/policy.";
    };

    masterKeyFile = lib.mkOption {
      type = lib.types.path;
      description = "Path to a file holding the master secret key. Mounted via systemd LoadCredential.";
    };

    extraArgs = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
    };
  };

  config = lib.mkIf cfg.enable {
    users.users.seal-key-server = {
      isSystemUser = true;
      group = "seal-key-server";
    };
    users.groups.seal-key-server = { };

    systemd.services.seal-key-server = {
      description = "Seal key-server";
      wantedBy = [ "multi-user.target" ];
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];

      serviceConfig = {
        Type = "exec";
        User = "seal-key-server";
        Group = "seal-key-server";
        LoadCredential = [ "master-key:${toString cfg.masterKeyFile}" ];
        Environment = [
          "MASTER_KEY_FILE=%d/master-key"
        ];
        ExecStart = lib.escapeShellArgs (
          [
            "${cfg.package}/bin/key-server"
            "--config" (toString cfg.configFile)
            "--listen" cfg.listenAddress
          ] ++ cfg.extraArgs
        );
        Restart = "on-failure";
        RestartSec = "10s";
      };
    };
  };
}
