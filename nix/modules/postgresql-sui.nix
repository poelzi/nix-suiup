{ config, lib, pkgs, ... }:

let
  cfg = config.services.postgresql-sui;
in
{
  options.services.postgresql-sui = {
    enable = lib.mkEnableOption "PostgreSQL preconfigured for sui-indexer-alt";

    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.postgresql_17;
      defaultText = lib.literalExpression "pkgs.postgresql_17";
      description = "PostgreSQL package. sui-indexer-alt schemas have been validated against pg17.";
    };

    port = lib.mkOption {
      type = lib.types.port;
      default = 5432;
      description = "TCP port the indexer database listens on.";
    };

    dataDir = lib.mkOption {
      type = lib.types.path;
      default = "/var/lib/postgresql/sui-indexer";
      description = "On-disk location of the cluster.";
    };

    indexerDatabase = lib.mkOption {
      type = lib.types.str;
      default = "sui_indexer";
      description = "Database name created for sui-indexer-alt.";
    };

    indexerUser = lib.mkOption {
      type = lib.types.str;
      default = "sui_indexer";
      description = "Role granted CRUD on the indexer database.";
    };

    enableTcp = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Listen on TCP (off => unix socket only).";
    };
  };

  config = lib.mkIf cfg.enable {
    # nixpkgs only auto-creates the cluster directory (via systemd
    # StateDirectory) when dataDir is the package default. With this custom
    # dataDir, 26.05's hardened postgresql.service fails at the NAMESPACE step
    # ("Failed to set up mount namespacing: ... No such file or directory")
    # because it bind-mounts dataDir before the pre-start script can mkdir it.
    # Create it (and its parent) up front so the service can start.
    systemd.tmpfiles.rules = [
      "d ${builtins.dirOf cfg.dataDir} 0755 postgres postgres - -"
      "d ${cfg.dataDir} 0700 postgres postgres - -"
    ];

    services.postgresql = {
      enable = true;
      package = cfg.package;
      dataDir = cfg.dataDir;
      enableTCPIP = cfg.enableTcp;
      settings.port = cfg.port;
      ensureDatabases = [ cfg.indexerDatabase ];
      ensureUsers = [
        {
          name = cfg.indexerUser;
          ensureDBOwnership = true;
        }
      ];
      authentication = lib.mkOverride 50 ''
        local all all              trust
        host  all all 127.0.0.1/32 trust
        host  all all ::1/128       trust
      '';
    };
  };
}
