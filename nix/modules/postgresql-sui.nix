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
