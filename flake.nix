{
  description = "cardano-transaction-lib";

  inputs = {
    flake-compat = {
      url = "github:edolstra/flake-compat";
      flake = false;
    };

    # for the purescript project
    ogmios.url = "github:mlabs-haskell/ogmios/c4f896bf32ad066be8edd8681ee11e4ab059be7f";
    ogmios-datum-cache = {
      url = "github:mlabs-haskell/ogmios-datum-cache";
      flake = false;
    };
    # so named because we also need a different version of the repo below
    # in the server inputs and we use this one just for the `cardano-cli`
    # executables
    cardano-node-exe = {
      url = "github:input-output-hk/cardano-node/ea8b632820db5546b22430bbb5ed8db4a2fef7dd";
    };
    cardano-configurations = {
      url = "github:input-output-hk/cardano-configurations";
      flake = false;
    };
    easy-purescript-nix = {
      url = "github:justinwoo/easy-purescript-nix";
      flake = false;
    };

    # for the haskell server
    iohk-nix.url = "github:input-output-hk/iohk-nix";
    haskell-nix.url = "github:mlabs-haskell/haskell.nix?ref=master";
    nixpkgs.follows = "haskell-nix/nixpkgs-unstable";
    cardano-addresses = {
      url =
        "github:input-output-hk/cardano-addresses/d2f86caa085402a953920c6714a0de6a50b655ec";
      flake = false;
    };
    cardano-base = {
      url =
        "github:input-output-hk/cardano-base/41545ba3ac6b3095966316a99883d678b5ab8da8";
      flake = false;
    };
    cardano-config = {
      url =
        "github:input-output-hk/cardano-config/fe7855e981072d392513f9cf3994e0b6eba40d7d";
      flake = false;
    };
    cardano-crypto = {
      url =
        "github:input-output-hk/cardano-crypto/f73079303f663e028288f9f4a9e08bcca39a923e";
      flake = false;
    };
    cardano-ledger = {
      url =
        "github:input-output-hk/cardano-ledger/1a9ec4ae9e0b09d54e49b2a40c4ead37edadcce5";
      flake = false;
    };
    cardano-node = {
      url =
        "github:input-output-hk/cardano-node/8909dea9b3996b8288f15f0e4f31fb0f63964197";
      flake = false;
    };
    cardano-prelude = {
      url =
        "github:input-output-hk/cardano-prelude/bb4ed71ba8e587f672d06edf9d2e376f4b055555";
      flake = false;
    };
    cardano-wallet = {
      url =
        "github:input-output-hk/cardano-wallet/ae7569293e94241ef6829139ec02bd91abd069df";
      flake = false;
    };
    ekg-forward = {
      url =
        "github:input-output-hk/ekg-forward/297cd9db5074339a2fb2e5ae7d0780debb670c63";
      flake = false;
    };
    flat = {
      url =
        "github:input-output-hk/flat/ee59880f47ab835dbd73bea0847dab7869fc20d8";
      flake = false;
    };
    goblins = {
      url =
        "github:input-output-hk/goblins/cde90a2b27f79187ca8310b6549331e59595e7ba";
      flake = false;
    };
    iohk-monitoring-framework = {
      url =
        "github:input-output-hk/iohk-monitoring-framework/808724ff8a19a33d0ed06f9ef59fbd900b08553c";
      flake = false;
    };
    optparse-applicative = {
      url =
        "github:input-output-hk/optparse-applicative/7497a29cb998721a9068d5725d49461f2bba0e7a";
      flake = false;
    };
    ouroboros-network = {
      url =
        "github:input-output-hk/ouroboros-network/d2d219a86cda42787325bb8c20539a75c2667132";
      flake = false;
    };
    plutus = {
      url =
        "github:input-output-hk/plutus/1efbb276ef1a10ca6961d0fd32e6141e9798bd11";
      flake = false;
    };
    # NOTE
    # I don't we need anything from `plutus-apps`, so the following two are
    # not necessary. They might be useful for communicating with the frontend
    # however in case this is needed
    purescript-bridge = {
      url =
        "github:shmish111/purescript-bridge/6a92d7853ea514be8b70bab5e72077bf5a510596";
      flake = false;
    };
    servant-purescript = {
      url =
        "github:shmish111/servant-purescript/a76104490499aa72d40c2790d10e9383e0dbde63";
      flake = false;
    };
    Win32-network = {
      url =
        "github:input-output-hk/Win32-network/3825d3abf75f83f406c1f7161883c438dac7277d";
      flake = false;
    };
  };

  outputs =
    { self
    , nixpkgs
    , haskell-nix
    , iohk-nix
    , cardano-configurations
    , ...
    }@inputs:
    let
      defaultSystems = [
        "x86_64-linux"
        "x86_64-darwin"
        "aarch64-linux"
        "aarch64-darwin"
      ];
      perSystem = nixpkgs.lib.genAttrs defaultSystems;
      overlay = system: with inputs; (prev: final: {
        easy-ps =
          import inputs.easy-purescript-nix { pkgs = prev; };
        ogmios-datum-cache =
          nixpkgs.legacyPackages.${system}.haskellPackages.callPackage
            ogmios-datum-cache
            { };
        ogmios = ogmios.packages.${system}."ogmios:exe:ogmios";
        cardano-cli = cardano-node-exe.packages.${system}.cardano-cli;
        purescriptProject = import ./nix { inherit system; pkgs = prev; };
        buildCtlRuntime = buildCtlRuntime system;
        launchCtlRuntime = launchCtlRuntime system;
        inherit cardano-configurations;
      });

      nixpkgsFor = system: import nixpkgs {
        overlays = [
          haskell-nix.overlay
          iohk-nix.overlays.crypto
          (overlay system)
        ];
        inherit (haskell-nix) config;
        inherit system;
      };

      buildCtlRuntime = system:
        { node ? { port = 3001; }
        , ogmios ? { port = 1337; }
        , ctlServer ? { port = 8081; }
        , postgres ? {
            port = 5432;
            user = "ctxlib";
            password = "ctxlib";
            db = "ctxlib";
          }
        , datumCache ? {
            port = 9999;
            dbConnectionString = nixpkgs.lib.concatStringsSep
              " "
              [
                "host=postgres"
                "port=${toString postgres.port}"
                "user=${postgres.user}"
                "dbname=${postgres.db}"
                "password=${postgres.password}"
              ];
            saveAllDatums = true;
            firstFetchBlock = {
              slot = 44366242;
              id = "d2a4249fe3d0607535daa26caf12a38da2233586bc51e79ed0b3a36170471bf5";
            };
          }
        }:
        { ... }:
        let
          inherit (builtins) toString;
          pkgs = nixpkgsFor system;
          nodeDbVol = "node-db";
          nodeIpcVol = "node-ipc";
          nodeSocketPath = "/ipc/node.socket";
          serverName = "ctl-server:exe:ctl-server";
          server = self.packages.${system}."${serverName}";
          bindPort = port: "${toString port}:${toString port}";
        in
        {
          docker-compose.raw = {
            volumes = {
              "${nodeDbVol}" = { };
              "${nodeIpcVol}" = { };
            };
          };
          services = {
            cardano-node = {
              service = {
                image = "inputoutput/cardano-node:1.34.1";
                ports = [ (bindPort node.port) ];
                volumes = [
                  "${cardano-configurations}/network/testnet/cardano-node:/config"
                  "${cardano-configurations}/network/testnet/genesis:/genesis"
                  "${nodeDbVol}:/data"
                  "${nodeIpcVol}:/ipc"
                ];
                command = [
                  "run"
                  "--config"
                  "/config/config.json"
                  "--database-path"
                  "/data/db"
                  "--socket-path"
                  "${nodeSocketPath}"
                  "--topology"
                  "/config/topology.json"
                ];
              };
            };
            ogmios = {
              service = {
                useHostStore = true;
                ports = [ (bindPort ogmios.port) ];
                volumes = [
                  "${cardano-configurations}/network/testnet:/config"
                  "${nodeIpcVol}:/ipc"
                ];
                command = [
                  "${pkgs.bash}/bin/sh"
                  "-c"
                  ''
                    ${pkgs.ogmios}/bin/ogmios \
                      --host 0.0.0.0 \
                      --port ${toString ogmios.port} \
                      --node-socket /ipc/node.socket \
                      --node-config /config/cardano-node/config.json
                  ''
                ];
              };
            };
            ctl-server = {
              service = {
                useHostStore = true;
                ports = [ (bindPort ctlServer.port) ];
                command = [
                  "${pkgs.bash}/bin/sh"
                  "-c"
                  ''
                    ${server}/bin/ctl-server \
                      --port ${toString ctlServer.port} \
                      --node-socket ${nodeSocketPath} \
                      --network-id 1097911063
                  ''
                ];
              };
            };
            postgres = {
              service = {
                image = "postgres:13";
                ports = [ (bindPort postgres.port) ];
                environment = {
                  POSTGRES_USER = "${postgres.user}";
                  POSTGRES_PASSWORD = "${postgres.password}";
                  POSTGRES_DB = "${postgres.db}";
                };
              };
            };
            ogmios-datum-cache =
              let
                configFile = ''
                  dbConnectionString = "${datumCache.dbConnectionString}"
                  saveAllDatums = ${pkgs.lib.boolToString datumCache.saveAllDatums}
                  server.port = ${toString datumCache.port}
                  ogmios.address = "ogmios"
                  ogmios.port = ${toString ogmios.port}
                  firstFetchBlock.slot = ${toString datumCache.firstFetchBlock.slot}
                  firstFetchBlock.id = "${datumCache.firstFetchBlock.id}"
                '';
              in
              {
                service = {
                  useHostStore = true;
                  ports = [ (bindPort datumCache.port) ];
                  restart = "on-failure";
                  depends_on = [ "postgres" ];
                  command = [
                    "${pkgs.bash}/bin/sh"
                    "-c"
                    ''
                      ${pkgs.coreutils}/bin/cat <<EOF > config.toml
                        ${configFile}
                      EOF
                      ${pkgs.coreutils}/bin/sleep 1
                      ${pkgs.ogmios-datum-cache}/bin/ogmios-datum-cache
                    ''
                  ];
                };
              };
          };
        };

      # Makes a set compatible with flake `apps` to launch all runtime services
      launchCtlRuntime = system: config:
        let
          pkgs = nixpkgsFor system;
          binPath = "ctl-runtime";
          prebuilt = (pkgs.arion.build {
            inherit pkgs;
            modules = [ (buildCtlRuntime system config) ];
          }).outPath;
          script = (pkgs.writeShellScriptBin "${binPath}"
            ''
              ${pkgs.arion}/bin/arion --prebuilt-file ${prebuilt} up
            ''
          ).overrideAttrs (_: {
            buildInputs = [ pkgs.arion pkgs.docker ];
          });
        in
        {
          type = "app";
          program = "${script}/bin/${binPath}";
        };

      psProjectFor = system:
        let
          pkgs = nixpkgsFor system;
          src = self;
          project = pkgs.purescriptProject {
            inherit src pkgs;
            projectName = "cardano-transaction-lib";
            shell = {
              packages = [
                pkgs.ogmios
                pkgs.cardano-cli
                pkgs.ogmios-datum-cache
                pkgs.nixpkgs-fmt
                pkgs.fd
                pkgs.arion
              ];
            };
          };
        in
        rec {
          defaultPackage = packages.ctl-example-bundle-web;

          # Building this package and the check below will ensure that the entire
          # project compiles (i.e. all of `src`, `examples`, and `test`)
          packages = {
            ctl-example-bundle-web = project.bundlePursProject {
              sources = [ "src" "examples" ];
              main = "Examples.Pkh2Pkh";
              entrypoint = "examples/index.js";
              htmlTemplate = "examples/index.html";
            };

            ctl-runtime = pkgs.arion.build {
              inherit pkgs;
              modules = [ (buildCtlRuntime system { }) ];
            };

            docs = project.buildSearchablePursDocs;
          };

          launchDocs =
            let
              binPath = "docs-server";
              builtDocs = packages.docs;
              script = (pkgs.writeShellScriptBin "${binPath}"
                ''
                  ${pkgs.nodePackages.http-server}/bin/http-server ${builtDocs}/generated-docs/html
                ''
              ).overrideAttrs (_: {
                buildInputs = [ pkgs.nodejs-14_x pkgs.nodePackages.http-server ];
              });
            in
            {
              type = "app";
              program = "${script}/bin/${binPath}";
            };

          # FIXME
          # Once we have ogmios/node instances available, we should also include a
          # test. This will need to be run via a Hercules `effect`
          checks = {
            ctl-unit-test = project.runPursTest {
              testMain = "Test.Unit";
              sources = [ "src" "test" "fixtures" ];
            };
          };

          devShell = project.devShell;
        };

      hsProjectFor = system:
        let
          pkgs = nixpkgsFor system;
          src = ./server;
        in
        import ./server/nix {
          inherit src inputs pkgs system;
        };
    in
    {
      # flake from haskell.nix project
      hsFlake = perSystem (system: (hsProjectFor system).flake { });

      devShell = perSystem (system: self.devShells.${system}.ctl);

      devShells = perSystem (system: {
        # This is the default `devShell` and can be run without specifying
        # it (i.e. `nix develop`)
        ctl = (psProjectFor system).devShell;
        # It might be a good idea to keep this as a separate shell; if you're
        # working on the PS frontend, it doesn't make a lot of sense to pull
        # in all of the Haskell dependencies
        #
        # This can be used with `nix develop .#hsDevShell
        hsDevShell = self.hsFlake.${system}.devShell;
      });

      packages = perSystem (system:
        self.hsFlake.${system}.packages
        // (psProjectFor system).packages
      );

      apps = perSystem
        (system: {
          inherit
            (self.hsFlake.${system}.apps) "ctl-server:exe:ctl-server";
          ctl-runtime = (nixpkgsFor system).launchCtlRuntime { };
          docs = (psProjectFor system).launchDocs;
        });

      checks = perSystem (system:
        let
          pkgs = nixpkgsFor system;
        in
        (psProjectFor system).checks
        // self.hsFlake.${system}.checks
        // {
          formatting-check = pkgs.runCommand "formatting-check"
            {
              nativeBuildInputs = with pkgs; [
                easy-ps.purs-tidy
                haskellPackages.fourmolu
                nixpkgs-fmt
                fd
              ];
            }
            ''
              cd ${self}
              purs-tidy check $(fd -epurs)
              fourmolu -m check -o -XTypeApplications -o -XImportQualifiedPost \
                $(fd -ehs)
              nixpkgs-fmt --check $(fd -enix --exclude='spago*')
              touch $out
            '';
        });

      check = perSystem (system:
        (nixpkgsFor system).runCommand "combined-check"
          {
            nativeBuildInputs =
              builtins.attrValues self.checks.${system}
              ++ builtins.attrValues self.packages.${system};
          }
          ''
            touch $out
          ''
      );

      defaultPackage = perSystem (system: (psProjectFor system).defaultPackage);

      overlay = perSystem overlay;

      herculesCI.ciSystems = [ "x86_64-linux" ];
    };
}
