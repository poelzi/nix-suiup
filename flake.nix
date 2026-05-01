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

        sourceReleaseDir = ./nix/source-releases;
        sourceReleaseFileNames = builtins.attrNames (builtins.readDir sourceReleaseDir);
        sourceReleaseNixFiles = builtins.sort (a: b: a < b) (
          builtins.filter (name: pkgs.lib.hasSuffix ".nix" name) sourceReleaseFileNames
        );
        sourceReleases = builtins.listToAttrs (
          map (
            file:
            let
              release = import (sourceReleaseDir + "/${file}");
            in
            pkgs.lib.nameValuePair release.tag release
          ) sourceReleaseNixFiles
        );

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

            doCheck = false;

            meta = with pkgs.lib; {
              description = "${binaryName} built from MystenLabs/sui source (${release.tag})";
              homepage = "https://github.com/MystenLabs/sui";
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

        getLatestSourceMainnet =
          let
            mainnetReleases = pkgs.lib.filterAttrs (tag: _: pkgs.lib.hasPrefix "mainnet-" tag) sourceReleases;
            sortedTags = builtins.sort (a: b: a > b) (builtins.attrNames mainnetReleases);
          in
          if sortedTags == [ ] then null else builtins.head sortedTags;

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
              standalonePackagesAttrs."walrus-${getLatestMainnet "walrus"}";
          latest-walrus-sites =
            mkLatestAliasCheck "walrus-sites"
              standalonePackagesAttrs."walrus-sites-${getLatestMainnet "walrus-sites"}";
        };

        packages = {
          # Default build without patchelf
          default = mkSuiup { enablePatchelf = true; };

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
              latest = getLatestMainnet "walrus";
            in
            if latest != null then
              standalonePackagesAttrs."walrus-${latest}"
            else
              throw "No mainnet walrus release found";

          walrus-sites =
            let
              latest = getLatestMainnet "walrus-sites";
            in
            if latest != null then
              standalonePackagesAttrs."walrus-sites-${latest}"
            else
              throw "No mainnet walrus-sites release found";
        }
        // standalonePackagesAttrs
        // sourcePackagesAttrs;

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

        apps = {
          default = {
            type = "app";
            program = "${self.packages.${system}.default}/bin/suiup";
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
    );
}
