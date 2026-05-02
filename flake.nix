{
  description = "Sui Tooling Version Manager";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
    pre-commit-hooks = {
      url = "github:cachix/git-hooks.nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      flake-utils,
      pre-commit-hooks,
    }:
    flake-utils.lib.eachDefaultSystem (
      system:
      let
        pkgs = import nixpkgs { inherit system; };

        # Standalone releases: version -> hash mapping
        # These are pre-built binaries that will be patched with Nix dependencies
        # Update with: nix run .#update-releases
        standaloneReleases = builtins.fromJSON (builtins.readFile ./nix/releases.json);

        # Load all *.nix release pin files from a directory into a tag -> release attrset.
        loadReleasesFromDir =
          dir:
          let
            fileNames = builtins.attrNames (builtins.readDir dir);
            nixFiles = builtins.sort (a: b: a < b) (
              builtins.filter (name: pkgs.lib.hasSuffix ".nix" name) fileNames
            );
          in
          builtins.listToAttrs (
            map (
              file:
              let
                release = import (dir + "/${file}");
              in
              pkgs.lib.nameValuePair release.tag release
            ) nixFiles
          );

        # Pick the highest mainnet-* tag in a releases attrset (or null if none).
        latestMainnetTag =
          releases:
          let
            mainnet = pkgs.lib.filterAttrs (tag: _: pkgs.lib.hasPrefix "mainnet-" tag) releases;
            sortedTags = builtins.sort (a: b: a > b) (builtins.attrNames mainnet);
          in
          if sortedTags == [ ] then null else builtins.head sortedTags;

        sourceReleases = loadReleasesFromDir ./nix/source-releases;
        walrusSourceReleases = loadReleasesFromDir ./nix/source-releases-walrus;
        sealSourceReleases = loadReleasesFromDir ./nix/source-releases-seal;

        rustToolchain = {
          cargo = pkgs.cargo;
          rustc = pkgs.rustc;
          rustfmt = pkgs.rustfmt;
          rustLibSrc = pkgs.rustPlatform.rustLibSrc;
        };

        rustToolchainSui = rustToolchain;
        rustPlatformSui = pkgs.makeRustPlatform {
          cargo = rustToolchainSui.cargo;
          rustc = rustToolchainSui.rustc;
        };

        buildInputs =
          with pkgs;
          [
            openssl
            pkg-config
          ]
          ++ lib.optionals stdenv.isDarwin [
            darwin.apple_sdk.frameworks.Security
            darwin.apple_sdk.frameworks.SystemConfiguration
          ];

        nativeBuildInputs = with pkgs; [
          rustToolchain.cargo
          rustToolchain.rustc
          pkg-config
        ];

        # These libraries will be added to the RPATH of the patched binary
        runtimeLibs = with pkgs; [
          stdenv.cc.cc.lib # libstdc++.so.6, libgcc_s.so.1
          glibc # libc.so.6, libm.so.6, libpthread.so.0, libdl.so.2
          openssl # libssl.so, libcrypto.so (for reqwest with rustls-tls)
          zlib # libz.so.1 (for flate2)
        ];
      in
      let

        # Build the library path string
        patchData = (
          builtins.toJSON {
            lib_path = "${(pkgs.lib.makeLibraryPath runtimeLibs)}";
            interpreter = "${pkgs.glibc}/lib/ld-linux-x86-64.so.2";
          }
        );

        # Import runtime dependencies configuration
        #runtimeDeps = import ./nix-runtime-deps.nix { inherit pkgs; };

        # Function to build suiup with optional patchelf
        mkSuiup =
          {
            enablePatchelf ? false,
          }:
          pkgs.rustPlatform.buildRustPackage {
            pname = "suiup";
            version = "0.0.4";

            inherit buildInputs patchData;

            src = ./.;
            # passAsFile = [ "patchData"];
            cargoLock = {
              lockFile = ./Cargo.lock;
            };

            nativeBuildInputs =
              nativeBuildInputs
              ++ pkgs.lib.optionals enablePatchelf [
                pkgs.patchelf
              ];

            doCheck = false;

            passAsFile = [ "patchData" ];

            # Enable the nix-patchelf feature when building with patchelf
            buildFeatures = pkgs.lib.optionals enablePatchelf [ "nix-patchelf" ];

            postPatch = pkgs.lib.optionalString enablePatchelf ''
              substituteInPlace src/patchelf.rs \
                --replace-fail '"patchelf"' '"${pkgs.patchelf}/bin/patchelf"' \
                --replace-fail '/usr/share/suiup/nix-runtime-deps.json' "$out/share/suiup/nix-runtime-deps.json"
            '';

            # Install the runtime dependencies JSON file and patch suiup binary
            postInstall = pkgs.lib.optionalString enablePatchelf ''
              echo "Setting up Nix patchelf support..."

              # Create the data directory for runtime deps config
              mkdir -p $out/share/suiup
              cp $patchDataPath $out/share/suiup/nix-runtime-deps.json;
            '';

            meta = with pkgs.lib; {
              description = "Sui Tooling Version Manager";
              homepage = "https://github.com/Mystenlabs/suiup";
              license = licenses.asl20;
              maintainers = [ ];
              mainProgram = "suiup";
            };
          };

        # Function to create a patched standalone binary package
        # This downloads a pre-built binary or .tgz and patches it using suiup's patchelf process
        mkStandaloneBinary =
          {
            binaryName,
            version,
            hash,
            url,
          }:
          let
            # Determine if this is a .tgz archive
            isTgz = pkgs.lib.hasSuffix ".tgz" url;
            # Map package name to actual binary name in archive
            # walrus-sites package contains site-builder binary
            actualBinaryName = if binaryName == "walrus-sites" then "site-builder" else binaryName;
          in
          pkgs.stdenv.mkDerivation {
            pname = binaryName;
            inherit version;

            src = pkgs.fetchurl {
              inherit url hash;
            };

            nativeBuildInputs = [
              pkgs.patchelf
            ]
            ++ pkgs.lib.optionals isTgz [
              pkgs.gnutar
              pkgs.gzip
            ];

            buildInputs = runtimeLibs;

            unpackPhase =
              if isTgz then
                ''
                  runHook preUnpack
                  tar -xzf $src
                  runHook postUnpack
                ''
              else
                ''
                  runHook preUnpack
                  # For direct binaries, just copy the file
                  cp $src binary
                  runHook postUnpack
                '';

            dontBuild = true;

            installPhase = ''
              runHook preInstall

              mkdir -p $out/bin

              # Find the binary file
              ${
                if isTgz then
                  ''
                    # For .tgz archives, find and extract the binary
                    # The binary is typically at the root or in a bin directory
                    if [ -f ${actualBinaryName} ]; then
                      BINARY_PATH=${actualBinaryName}
                    elif [ -f bin/${actualBinaryName} ]; then
                      BINARY_PATH=bin/${actualBinaryName}
                    else
                      echo "Error: Could not find binary ${actualBinaryName} in archive"
                      find . -type f
                      exit 1
                    fi
                    install -D -m755 "$BINARY_PATH" $out/bin/${binaryName}
                  ''
                else
                  ''
                    # For direct binaries
                    install -D -m755 binary $out/bin/${binaryName}
                  ''
              }

              # Apply the same patching that suiup does
              echo "Patching ${binaryName} binary..."
              patchelf \
                --set-interpreter ${pkgs.glibc}/lib/ld-linux-x86-64.so.2 \
                --set-rpath ${pkgs.lib.makeLibraryPath runtimeLibs} \
                $out/bin/${binaryName}

              runHook postInstall
            '';

            meta = with pkgs.lib; {
              description = "Patched ${binaryName} standalone binary";
              platforms = [ "x86_64-linux" ];
              mainProgram = binaryName;
            };
          };

        mkSuiSourceBinary =
          {
            binaryName,
            release,
          }:
          let
            fetchedSrc = pkgs.fetchFromGitHub {
              owner = "MystenLabs";
              repo = "sui";
              rev = release.rev;
              hash = release.srcHash;
            };
          in
          rustPlatformSui.buildRustPackage {
            pname = "${binaryName}-source";
            version = release.tag;

            src = fetchedSrc;

            cargoHash = release.cargoHash;
            cargoBuildFlags = [ "--bin=${binaryName}" ];

            nativeBuildInputs = [
              pkgs.cmake
              pkgs.clang
              pkgs.pkg-config
              pkgs.protobuf
            ];

            buildInputs = [
              pkgs.openssl
              pkgs.zlib
            ]
            ++ pkgs.lib.optionals pkgs.stdenv.isDarwin [
              pkgs.darwin.apple_sdk.frameworks.Security
              pkgs.darwin.apple_sdk.frameworks.SystemConfiguration
            ];

            LIBCLANG_PATH = "${pkgs.llvmPackages.libclang.lib}/lib";
            PROTOC = "${pkgs.protobuf}/bin/protoc";

            # The bin_version macro reads these at compile time; without them
            # it panics ("unable to query git revision") because fetchFromGitHub
            # strips the .git directory.
            GIT_REVISION = release.rev;
            VERGEN_GIT_SHA = release.rev;

            # gcc >= 13 no longer transitively includes <cstdint>; the vendored
            # rocksdb headers in librocksdb-sys reference uint64_t etc. without
            # it. Scope the force-include to C++ via CXXFLAGS (cc-rs honors
            # this only for C++ compilation, leaving C and .S builds alone).
            env.CXXFLAGS = "-include cstdint";

            doCheck = false;

            meta = with pkgs.lib; {
              description = "${binaryName} built from MystenLabs/sui source (${release.tag})";
              homepage = "https://github.com/MystenLabs/sui";
              license = licenses.asl20;
              maintainers = [ ];
              mainProgram = binaryName;
            };
          };

        mkSealSourceBinary =
          {
            binaryName,
            release,
          }:
          let
            fetchedSrc = pkgs.fetchFromGitHub {
              owner = "MystenLabs";
              repo = "seal";
              rev = release.rev;
              hash = release.srcHash;
            };
          in
          rustPlatformSui.buildRustPackage {
            pname = "${binaryName}-source";
            version = release.tag;

            src = fetchedSrc;

            cargoHash = release.cargoHash;
            cargoBuildFlags = [ "--bin=${binaryName}" ];

            nativeBuildInputs = [
              pkgs.cmake
              pkgs.clang
              pkgs.pkg-config
              pkgs.protobuf
            ];

            buildInputs = [
              pkgs.openssl
              pkgs.zlib
            ]
            ++ pkgs.lib.optionals pkgs.stdenv.isDarwin [
              pkgs.darwin.apple_sdk.frameworks.Security
              pkgs.darwin.apple_sdk.frameworks.SystemConfiguration
            ];

            LIBCLANG_PATH = "${pkgs.llvmPackages.libclang.lib}/lib";
            PROTOC = "${pkgs.protobuf}/bin/protoc";

            GIT_REVISION = release.rev;
            VERGEN_GIT_SHA = release.rev;
            env.CXXFLAGS = "-include cstdint";

            # Same sui-rpc-api build.rs vendor-workspace patch as mkWalrusSourceBinary.
            preBuild = ''
              # The cargo-vendor dir is a SIBLING of $sourceRoot — check ./, ../, /build.
              for crate in $(find . .. /build -maxdepth 6 -type d -name 'sui-rpc-api-*' 2>/dev/null); do
                [ -f "$crate/build.rs" ] || continue
                echo "[suiup] patching $crate/build.rs"
                cp ${./nix/patches/sui-rpc-api-build.rs} "$crate/build.rs"
                chmod u+w "$crate/build.rs"
              done
            '';

            doCheck = false;

            meta = with pkgs.lib; {
              description = "${binaryName} built from MystenLabs/seal source (${release.tag})";
              homepage = "https://github.com/MystenLabs/seal";
              license = licenses.asl20;
              maintainers = [ ];
              mainProgram = binaryName;
            };
          };

        mkWalrusSourceBinary =
          {
            binaryName,
            release,
          }:
          let
            fetchedSrc = pkgs.fetchFromGitHub {
              owner = "MystenLabs";
              repo = "walrus";
              rev = release.rev;
              hash = release.srcHash;
            };
          in
          rustPlatformSui.buildRustPackage {
            pname = "${binaryName}-source";
            version = release.tag;

            src = fetchedSrc;

            cargoHash = release.cargoHash;
            cargoBuildFlags = [ "--bin=${binaryName}" ];

            nativeBuildInputs = [
              pkgs.cmake
              pkgs.clang
              pkgs.pkg-config
              pkgs.protobuf
            ];

            buildInputs = [
              pkgs.openssl
              pkgs.zlib
            ]
            ++ pkgs.lib.optionals pkgs.stdenv.isDarwin [
              pkgs.darwin.apple_sdk.frameworks.Security
              pkgs.darwin.apple_sdk.frameworks.SystemConfiguration
            ];

            LIBCLANG_PATH = "${pkgs.llvmPackages.libclang.lib}/lib";
            PROTOC = "${pkgs.protobuf}/bin/protoc";

            # Same git-revision and rocksdb workarounds as mkSuiSourceBinary.
            GIT_REVISION = release.rev;
            VERGEN_GIT_SHA = release.rev;
            env.CXXFLAGS = "-include cstdint";

            # When sui-rpc-api is consumed as a vendored git dep (i.e. NOT
            # built from inside the sui workspace itself), its build.rs's
            # `cargo metadata` invocation returns nothing because there is no
            # surrounding workspace. Replace it with a sibling-directory walk
            # that works under cargo-vendor.
            preBuild = ''
              # The cargo-vendor dir is a SIBLING of $sourceRoot — check ./, ../, /build.
              for crate in $(find . .. /build -maxdepth 6 -type d -name 'sui-rpc-api-*' 2>/dev/null); do
                [ -f "$crate/build.rs" ] || continue
                echo "[suiup] patching $crate/build.rs"
                cp ${./nix/patches/sui-rpc-api-build.rs} "$crate/build.rs"
                chmod u+w "$crate/build.rs"
              done
            '';

            doCheck = false;

            meta = with pkgs.lib; {
              description = "${binaryName} built from MystenLabs/walrus source (${release.tag})";
              homepage = "https://github.com/MystenLabs/walrus";
              license = licenses.asl20;
              maintainers = [ ];
              mainProgram = binaryName;
            };
          };

        # Generate all standalone binary packages
        standalonePackages = pkgs.lib.flatten (
          pkgs.lib.mapAttrsToList (
            binaryName: versions:
            pkgs.lib.mapAttrsToList (
              version: releaseInfo:
              let
                # Handle both old format (string hash) and new format ({hash, url})
                hash = if builtins.isString releaseInfo then releaseInfo else releaseInfo.hash;
                url =
                  if builtins.isString releaseInfo then
                    "https://github.com/MystenLabs/${binaryName}/releases/download/${version}/${binaryName}-ubuntu-x86_64"
                  else
                    releaseInfo.url;
              in
              pkgs.lib.nameValuePair "${binaryName}-${version}" (mkStandaloneBinary {
                inherit
                  binaryName
                  version
                  hash
                  url
                  ;
              })
            ) versions
          ) standaloneReleases
        );

        # Helper function to get the latest mainnet release for a binary
        # For tools with network prefixes (sui, walrus, walrus-sites), get mainnet version
        # For tools without network prefixes (mvr), get the latest version
        getLatestMainnet =
          binaryName:
          let
            versions = standaloneReleases.${binaryName} or { };
            # Try to get mainnet-prefixed versions first
            mainnetVersions = pkgs.lib.filterAttrs (version: _: pkgs.lib.hasPrefix "mainnet-" version) versions;
            # If no mainnet versions, use all versions (for tools like mvr)
            candidateVersions = if mainnetVersions == { } then versions else mainnetVersions;
            sortedVersions = builtins.sort (a: b: a > b) (builtins.attrNames candidateVersions);
          in
          if sortedVersions == [ ] then null else builtins.head sortedVersions;

        # Create standalone packages as an attrset first
        standalonePackagesAttrs = builtins.listToAttrs standalonePackages;

        sourceBinaryNames = [
          "sui"
          "sui-node"
          "move-analyzer"
          "sui-indexer-alt"
          "sui-indexer-alt-jsonrpc"
        ];

        sourcePackages = pkgs.lib.flatten (
          map (
            binaryName:
            map (
              tag:
              pkgs.lib.nameValuePair "${binaryName}-source-${tag}" (mkSuiSourceBinary {
                inherit binaryName;
                release = sourceReleases.${tag};
              })
            ) (builtins.attrNames sourceReleases)
          ) sourceBinaryNames
        );

        sourcePackagesAttrs = builtins.listToAttrs sourcePackages;

        getLatestSourceMainnet = latestMainnetTag sourceReleases;

        walrusSourceBinaryNames = [
          "walrus"
          "walrus-deploy"
          "walrus-node"
          "walrus-upload-relay"
        ];

        walrusSourcePackages = pkgs.lib.flatten (
          map (
            binaryName:
            map (
              tag:
              pkgs.lib.nameValuePair "${binaryName}-source-${tag}" (mkWalrusSourceBinary {
                inherit binaryName;
                release = walrusSourceReleases.${tag};
              })
            ) (builtins.attrNames walrusSourceReleases)
          ) walrusSourceBinaryNames
        );

        walrusSourcePackagesAttrs = builtins.listToAttrs walrusSourcePackages;

        getLatestWalrusSourceMainnet = latestMainnetTag walrusSourceReleases;

        walrusContracts =
          let
            release = walrusSourceReleases.${getLatestWalrusSourceMainnet};
            src = pkgs.fetchFromGitHub {
              owner = "MystenLabs";
              repo = "walrus";
              rev = release.rev;
              hash = release.srcHash;
            };
          in
          pkgs.runCommand "walrus-contracts-${release.tag}" { } ''
            mkdir -p "$out"
            cp -R ${src}/contracts "$out/contracts"
          '';

        localWalrusEnv = pkgs.writeShellApplication {
          name = "suiup-local-walrus-env";
          runtimeInputs = [
            standalonePackagesAttrs."sui-${getLatestMainnet "sui"}"
            walrusSourcePackagesAttrs."walrus-source-${getLatestWalrusSourceMainnet}"
            walrusSourcePackagesAttrs."walrus-deploy-source-${getLatestWalrusSourceMainnet}"
            walrusSourcePackagesAttrs."walrus-node-source-${getLatestWalrusSourceMainnet}"
            pkgs.bash
            pkgs.coreutils
            pkgs.curl
            pkgs.findutils
            pkgs.gawk
            pkgs.gnugrep
            pkgs.gnused
            pkgs.jq
          ];
          text = ''
            export SUIUP_WALRUS_CONTRACTS="''${SUIUP_WALRUS_CONTRACTS:-${walrusContracts}/contracts}"
            exec ${pkgs.bash}/bin/bash ${./nix/local-walrus-env.sh} "$@"
          '';
        };

        sealSourceBinaryNames = [
          "seal-cli"
          "key-server"
        ];

        sealSourcePackages = pkgs.lib.flatten (
          map (
            binaryName:
            map (
              tag:
              pkgs.lib.nameValuePair "${binaryName}-source-${tag}" (mkSealSourceBinary {
                inherit binaryName;
                release = sealSourceReleases.${tag};
              })
            ) (builtins.attrNames sealSourceReleases)
          ) sealSourceBinaryNames
        );

        sealSourcePackagesAttrs = builtins.listToAttrs sealSourcePackages;

        # Seal tags don't follow the mainnet-/testnet- naming; just take the
        # highest tag (lex-sort works since they all start with seal-vX.Y.Z).
        getLatestSeal =
          let
            sortedTags = builtins.sort (a: b: a > b) (builtins.attrNames sealSourceReleases);
          in
          if sortedTags == [ ] then null else builtins.head sortedTags;

        # Move-framework packages (move-stdlib, sui-framework, sui-system,
        # deepbook, bridge) extracted as their own derivations from each pinned
        # MystenLabs/sui source release, so downstream Move.lock can pin a
        # nix store path instead of fetching from GitHub at build time.
        suiFrameworkPackageNames = [
          "move-stdlib"
          "sui-framework"
          "sui-system"
          "deepbook"
          "bridge"
        ];

        mkSuiFrameworkPackage =
          {
            release,
            packageName,
          }:
          let
            fetchedSrc = pkgs.fetchFromGitHub {
              owner = "MystenLabs";
              repo = "sui";
              rev = release.rev;
              hash = release.srcHash;
            };
          in
          pkgs.runCommand "${packageName}-${release.tag}"
            {
              meta = {
                description = "MystenLabs/sui ${packageName} Move package (${release.tag})";
                homepage = "https://github.com/MystenLabs/sui";
                license = pkgs.lib.licenses.asl20;
              };
            }
            ''
              cp -r ${fetchedSrc}/crates/sui-framework/packages/${packageName} $out
              chmod -R u+w $out
            '';

        moveFrameworkPackages = pkgs.lib.flatten (
          map (
            packageName:
            map (
              tag:
              pkgs.lib.nameValuePair "${packageName}-${tag}" (mkSuiFrameworkPackage {
                inherit packageName;
                release = sourceReleases.${tag};
              })
            ) (builtins.attrNames sourceReleases)
          ) suiFrameworkPackageNames
        );

        moveFrameworkPackagesAttrs = builtins.listToAttrs moveFrameworkPackages;

        preCommitCheck = pre-commit-hooks.lib.${system}.run {
          src = ./.;
          hooks = {
            check-merge-conflicts.enable = true;
            end-of-file-fixer.enable = true;
            trim-trailing-whitespace.enable = true;
            rustfmt-local = {
              enable = true;
              name = "rustfmt";
              entry = "${rustToolchain.rustfmt}/bin/rustfmt --edition 2024 --check";
              language = "system";
              files = "\\.rs$";
            };
          };
        };

        mkLatestAliasCheck =
          aliasName: expectedPkg:
          pkgs.runCommand "check-${aliasName}-latest"
            {
              aliasDrv = self.packages.${system}.${aliasName}.drvPath;
              expectedDrv = expectedPkg.drvPath;
            }
            ''
              if [ "$aliasDrv" != "$expectedDrv" ]; then
                echo "${aliasName} alias is not pointing to newest release"
                echo "alias:    $aliasDrv"
                echo "expected: $expectedDrv"
                exit 1
              fi

              touch "$out"
            '';

      in
      {
        checks = {
          pre-commit = preCommitCheck;
          latest-sui = mkLatestAliasCheck "sui" sourcePackagesAttrs."sui-source-${getLatestSourceMainnet}";
          latest-sui-binary =
            mkLatestAliasCheck "sui-binary"
              standalonePackagesAttrs."sui-${getLatestMainnet "sui"}";
          latest-sui-node =
            mkLatestAliasCheck "sui-node"
              sourcePackagesAttrs."sui-node-source-${getLatestSourceMainnet}";
          latest-move-analyzer =
            mkLatestAliasCheck "move-analyzer"
              sourcePackagesAttrs."move-analyzer-source-${getLatestSourceMainnet}";
          latest-mvr = mkLatestAliasCheck "mvr" standalonePackagesAttrs."mvr-${getLatestMainnet "mvr"}";
          latest-walrus =
            mkLatestAliasCheck "walrus"
              walrusSourcePackagesAttrs."walrus-source-${getLatestWalrusSourceMainnet}";
          latest-walrus-binary =
            mkLatestAliasCheck "walrus-binary"
              standalonePackagesAttrs."walrus-${getLatestMainnet "walrus"}";
          latest-walrus-node =
            mkLatestAliasCheck "walrus-node"
              walrusSourcePackagesAttrs."walrus-node-source-${getLatestWalrusSourceMainnet}";
          latest-walrus-deploy =
            mkLatestAliasCheck "walrus-deploy"
              walrusSourcePackagesAttrs."walrus-deploy-source-${getLatestWalrusSourceMainnet}";
          latest-walrus-upload-relay =
            mkLatestAliasCheck "walrus-upload-relay"
              walrusSourcePackagesAttrs."walrus-upload-relay-source-${getLatestWalrusSourceMainnet}";
          latest-walrus-sites =
            mkLatestAliasCheck "walrus-sites"
              standalonePackagesAttrs."walrus-sites-${getLatestMainnet "walrus-sites"}";
          latest-seal = mkLatestAliasCheck "seal" sealSourcePackagesAttrs."seal-cli-source-${getLatestSeal}";
          latest-seal-server =
            mkLatestAliasCheck "seal-server"
              sealSourcePackagesAttrs."key-server-source-${getLatestSeal}";
          latest-sui-indexer-alt =
            mkLatestAliasCheck "sui-indexer-alt"
              sourcePackagesAttrs."sui-indexer-alt-source-${getLatestSourceMainnet}";
          latest-sui-indexer-alt-jsonrpc =
            mkLatestAliasCheck "sui-indexer-alt-jsonrpc"
              sourcePackagesAttrs."sui-indexer-alt-jsonrpc-source-${getLatestSourceMainnet}";

          local-walrus-env-syntax = pkgs.runCommand "local-walrus-env-syntax" { } ''
            ${pkgs.bash}/bin/bash -n ${./nix/local-walrus-env.sh}
            touch "$out"
          '';

          # NixOS VM smoke test: boots `postgres + sui start` in a VM and
          # verifies the JSON-RPC answers. Uses the standalone (.#sui-binary)
          # to avoid forcing a full source build — for source-build coverage
          # use `nix build .#sui` directly.
          testHarnessSmoke = pkgs.nixosTest {
            name = "suiup-test-harness-smoke";
            nodes.machine =
              { ... }:
              {
                imports = [
                  self.nixosModules.postgresql-sui
                ];

                services.postgresql-sui.enable = true;

                environment.systemPackages = [ self.packages.${system}.sui-binary ];

                systemd.services.sui-local-net = {
                  description = "sui start --force-regenesis (test harness)";
                  wantedBy = [ "multi-user.target" ];
                  after = [
                    "network-online.target"
                    "postgresql.service"
                  ];
                  wants = [
                    "network-online.target"
                    "postgresql.service"
                  ];
                  serviceConfig = {
                    Type = "exec";
                    Restart = "on-failure";
                    RestartSec = "5s";
                    StateDirectory = "sui-local-net";
                    WorkingDirectory = "/var/lib/sui-local-net";
                    ExecStart = pkgs.lib.escapeShellArgs [
                      "${self.packages.${system}.sui-binary}/bin/sui"
                      "start"
                      "--force-regenesis"
                      "--with-faucet=0.0.0.0:9123"
                      "--with-indexer=postgres://sui_indexer@127.0.0.1:5432/sui_indexer"
                      "--fullnode-rpc-port"
                      "9000"
                      "--epoch-duration-ms"
                      "60000"
                      "--network.config"
                      "/var/lib/sui-local-net/sui-config"
                    ];
                  };
                };

                # The local network needs ample fds.
                systemd.extraConfig = ''
                  DefaultLimitNOFILE=65536
                '';
              };

            testScript = ''
              machine.start()
              machine.wait_for_unit("postgresql.service")
              machine.wait_for_unit("sui-local-net.service")
              machine.wait_for_open_port(9000, timeout=180)
              machine.wait_for_open_port(9123, timeout=180)
              # Smoke RPC: should return some JSON containing "jsonrpc"
              machine.succeed(
                  "curl -sf -X POST -H 'Content-Type: application/json' "
                  "-d '{\"jsonrpc\":\"2.0\",\"method\":\"suix_getReferenceGasPrice\",\"params\":[],\"id\":1}' "
                  "http://127.0.0.1:9000 | grep -q jsonrpc"
              )
              # Faucet must answer with a 2xx for a basic GET (rejects but reachable).
              machine.succeed("curl -sf -o /dev/null -w '%{http_code}' http://127.0.0.1:9123/ | grep -E '^(2|4)' >/dev/null")
            '';
          };
        };

        packages = rec {
          # The suiup CLI itself.
          suiup = mkSuiup { enablePatchelf = true; };

          # Default link-farm: every Sui-ecosystem tool we ship plus suiup.
          # `nix run` resolves to suiup via mainProgram.
          default = pkgs.symlinkJoin {
            name = "suiup-toolkit";
            paths = [
              suiup
              sui
              sui-node
              move-analyzer
              sui-indexer-alt
              sui-indexer-alt-jsonrpc
              walrus
              walrus-deploy
              walrus-node
              walrus-upload-relay
              walrus-sites
              seal
              seal-server
              mvr
              local-walrus-env
            ];
            meta = {
              description = "Sui toolkit: suiup + Sui/Walrus/Seal source tools, site-builder/mvr binaries, and local Sui/Walrus test harness";
              mainProgram = "suiup";
            };
          };

          # Aliases to latest mainnet releases
          sui =
            let
              latest = getLatestSourceMainnet;
            in
            if latest != null then
              sourcePackagesAttrs."sui-source-${latest}"
            else
              throw "No mainnet source-built sui release found";

          sui-binary =
            let
              latest = getLatestMainnet "sui";
            in
            if latest != null then
              standalonePackagesAttrs."sui-${latest}"
            else
              throw "No mainnet sui binary release found";

          sui-node =
            let
              latest = getLatestSourceMainnet;
            in
            if latest != null then
              sourcePackagesAttrs."sui-node-source-${latest}"
            else
              throw "No mainnet source-built sui-node release found";

          move-analyzer =
            let
              latest = getLatestSourceMainnet;
            in
            if latest != null then
              sourcePackagesAttrs."move-analyzer-source-${latest}"
            else
              throw "No mainnet source-built move-analyzer release found";

          mvr =
            let
              latest = getLatestMainnet "mvr";
            in
            if latest != null then standalonePackagesAttrs."mvr-${latest}" else throw "No mvr release found";

          walrus =
            let
              latest = getLatestWalrusSourceMainnet;
            in
            if latest != null then
              walrusSourcePackagesAttrs."walrus-source-${latest}"
            else
              throw "No mainnet source-built walrus release found";

          walrus-binary =
            let
              latest = getLatestMainnet "walrus";
            in
            if latest != null then
              standalonePackagesAttrs."walrus-${latest}"
            else
              throw "No mainnet walrus binary release found";

          walrus-node =
            let
              latest = getLatestWalrusSourceMainnet;
            in
            if latest != null then
              walrusSourcePackagesAttrs."walrus-node-source-${latest}"
            else
              throw "No mainnet source-built walrus-node release found";

          walrus-deploy =
            let
              latest = getLatestWalrusSourceMainnet;
            in
            if latest != null then
              walrusSourcePackagesAttrs."walrus-deploy-source-${latest}"
            else
              throw "No mainnet source-built walrus-deploy release found";

          walrus-upload-relay =
            let
              latest = getLatestWalrusSourceMainnet;
            in
            if latest != null then
              walrusSourcePackagesAttrs."walrus-upload-relay-source-${latest}"
            else
              throw "No mainnet source-built walrus-upload-relay release found";

          walrus-sites =
            let
              latest = getLatestMainnet "walrus-sites";
            in
            if latest != null then
              standalonePackagesAttrs."walrus-sites-${latest}"
            else
              throw "No mainnet walrus-sites release found";

          seal =
            let
              latest = getLatestSeal;
            in
            if latest != null then
              sealSourcePackagesAttrs."seal-cli-source-${latest}"
            else
              throw "No seal release found";

          seal-server =
            let
              latest = getLatestSeal;
            in
            if latest != null then
              sealSourcePackagesAttrs."key-server-source-${latest}"
            else
              throw "No seal release found";

          # Move framework aliases (latest mainnet sui release) for use as Move.lock pins.
          move-stdlib =
            let
              latest = getLatestSourceMainnet;
            in
            if latest != null then
              moveFrameworkPackagesAttrs."move-stdlib-${latest}"
            else
              throw "No mainnet source-built sui release found";

          sui-framework =
            let
              latest = getLatestSourceMainnet;
            in
            if latest != null then
              moveFrameworkPackagesAttrs."sui-framework-${latest}"
            else
              throw "No mainnet source-built sui release found";

          sui-system =
            let
              latest = getLatestSourceMainnet;
            in
            if latest != null then
              moveFrameworkPackagesAttrs."sui-system-${latest}"
            else
              throw "No mainnet source-built sui release found";

          deepbook =
            let
              latest = getLatestSourceMainnet;
            in
            if latest != null then
              moveFrameworkPackagesAttrs."deepbook-${latest}"
            else
              throw "No mainnet source-built sui release found";

          bridge =
            let
              latest = getLatestSourceMainnet;
            in
            if latest != null then
              moveFrameworkPackagesAttrs."bridge-${latest}"
            else
              throw "No mainnet source-built sui release found";

          sui-indexer-alt =
            let
              latest = getLatestSourceMainnet;
            in
            if latest != null then
              sourcePackagesAttrs."sui-indexer-alt-source-${latest}"
            else
              throw "No mainnet source-built sui release found";

          sui-indexer-alt-jsonrpc =
            let
              latest = getLatestSourceMainnet;
            in
            if latest != null then
              sourcePackagesAttrs."sui-indexer-alt-jsonrpc-source-${latest}"
            else
              throw "No mainnet source-built sui release found";

          local-walrus-env = localWalrusEnv;
        }
        // standalonePackagesAttrs
        // sourcePackagesAttrs
        // walrusSourcePackagesAttrs
        // sealSourcePackagesAttrs
        // moveFrameworkPackagesAttrs;

        devShells.default = pkgs.mkShell {
          inherit buildInputs;

          nativeBuildInputs =
            nativeBuildInputs
            ++ (with pkgs; [
              cargo-watch
              rust-analyzer
              patchelf
            ])
            ++ preCommitCheck.enabledPackages;

          RUST_SRC_PATH = "${rustToolchain.rustLibSrc}/library";

          # Set up XDG_DATA_HOME to point to a local directory for development
          shellHook = ''
            export XDG_DATA_HOME="''${XDG_DATA_HOME:-$HOME/.local/share}"
            ${preCommitCheck.shellHook}
            echo "Nix development shell for suiup"
            echo "XDG_DATA_HOME: $XDG_DATA_HOME"
          '';
        };

        # NixOS modules are exposed at the top level (see outputs below).

        apps = {
          default = {
            type = "app";
            program = "${self.packages.${system}.default}/bin/suiup";
          };

          test-env = {
            type = "app";
            # Boots a private postgres + `sui start --with-faucet --with-indexer
            # --with-graphql` in a state dir. Endpoints printed at startup;
            # consumer test suites read SUI_RPC_URL / SUI_FAUCET_URL / DATABASE_URL.
            program = toString (
              pkgs.writeShellScript "suiup-test-env" ''
                set -euo pipefail
                export PATH="${
                  pkgs.lib.makeBinPath [
                    self.packages.${system}.sui
                    pkgs.postgresql_17
                    pkgs.coreutils
                    pkgs.gnused
                    pkgs.findutils
                  ]
                }:$PATH"
                exec ${pkgs.bash}/bin/bash ${./nix/test-env.sh} "$@"
              ''
            );
          };

          local-walrus-env = {
            type = "app";
            program = "${self.packages.${system}.local-walrus-env}/bin/suiup-local-walrus-env";
          };

          update-releases = {
            type = "app";
            program = toString (
              pkgs.writeShellScript "update-releases" ''
                set -e
                export PATH="${
                  pkgs.lib.makeBinPath [
                    pkgs.python3
                    pkgs.nix
                    pkgs.git
                  ]
                }:$PATH"

                # Check if we're in a git repository
                if ! ${pkgs.git}/bin/git rev-parse --git-dir > /dev/null 2>&1; then
                  echo "Error: This command must be run from within the suiup git repository"
                  exit 1
                fi

                # Find the script in the nix directory
                if [ -f "./nix/update-standalone-releases.py" ]; then
                  # Pass nix/releases.json as the file to update, forward any additional arguments (like --force)
                  exec ${pkgs.python3}/bin/python3 ./nix/update-standalone-releases.py nix/releases.json "$@"
                else
                  echo "Error: nix/update-standalone-releases.py not found"
                  exit 1
                fi
              ''
            );
          };
        };
      }
    )
    // {
      # System-agnostic outputs.
      nixosModules = rec {
        postgresql-sui = ./nix/modules/postgresql-sui.nix;
        sui-fullnode = ./nix/modules/sui-fullnode.nix;
        sui-indexer-alt = ./nix/modules/sui-indexer-alt.nix;
        sui-indexer-alt-jsonrpc = ./nix/modules/sui-indexer-alt-jsonrpc.nix;
        walrus-aggregator = ./nix/modules/walrus-aggregator.nix;
        walrus-publisher = ./nix/modules/walrus-publisher.nix;
        seal-key-server = ./nix/modules/seal-key-server.nix;
        sui-stack = ./nix/modules/sui-stack.nix;

        # Importing nixosModules.default pulls in every per-service module
        # plus the meta wrap, and auto-injects `suiupPackages` from this flake.
        default =
          { pkgs, ... }:
          {
            imports = [
              postgresql-sui
              sui-fullnode
              sui-indexer-alt
              sui-indexer-alt-jsonrpc
              walrus-aggregator
              walrus-publisher
              seal-key-server
              sui-stack
            ];
            _module.args.suiupPackages = self.packages.${pkgs.system};
          };
      };
    };
}
