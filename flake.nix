{
  description = "Community Nix packages and NixOS module for NVIDIA NemoClaw";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    nemoclaw-src = {
      url = "github:NVIDIA/NemoClaw/v0.0.86";
      flake = false;
    };

    dgx-spark = {
      url = "github:graham33/nixos-dgx-spark";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    pyproject-nix = {
      url = "github:pyproject-nix/pyproject.nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    uv2nix = {
      url = "github:pyproject-nix/uv2nix";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.pyproject-nix.follows = "pyproject-nix";
    };

    pyproject-build-systems = {
      url = "github:pyproject-nix/build-system-pkgs";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.pyproject-nix.follows = "pyproject-nix";
      inputs.uv2nix.follows = "uv2nix";
    };
  };

  outputs =
    inputs@{
      self,
      nixpkgs,
      nemoclaw-src,
      dgx-spark,
      pyproject-nix,
      uv2nix,
      pyproject-build-systems,
      ...
    }:
    let
      supportedSystems = [
        "aarch64-linux"
        "x86_64-linux"
      ];
      forAllSystems = nixpkgs.lib.genAttrs supportedSystems;
      mkVllmPackage =
        pkgs:
        import ./nix/vllm.nix {
          inherit
            pkgs
            pyproject-nix
            uv2nix
            pyproject-build-systems
            supportedSystems
            ;
          lib = nixpkgs.lib;
        };
      overlay = final: _prev: rec {
        openshell-nemoclaw = final.callPackage ./nix/openshell.nix { };
        nemoclaw = final.callPackage ./nix/nemoclaw.nix {
          src = nemoclaw-src;
          openshell = openshell-nemoclaw;
        };
        vllm-nemoclaw = mkVllmPackage final;
        nixclaw-platform = final.python312Packages.callPackage ./nix/nixclaw-platform.nix {
          inherit (final)
            nix
            patch
            openssh
            curl
            systemd
            coreutils
            ;
        };
      };
      pkgsFor =
        system:
        import nixpkgs {
          inherit system;
          config.allowUnfree = true;
          overlays = [ overlay ];
        };
    in
    {
      overlays.default = overlay;

      packages = forAllSystems (
        system:
        let
          pkgs = pkgsFor system;
        in
        {
          default = pkgs.nemoclaw;
          inherit (pkgs) nemoclaw;
          openshell = pkgs.openshell-nemoclaw;
          vllm = pkgs.vllm-nemoclaw;
          inherit (pkgs) nixclaw-platform;
        }
      );

      apps = forAllSystems (system: {
        default = self.apps.${system}.nemoclaw;
        nemoclaw = {
          type = "app";
          program = "${self.packages.${system}.nemoclaw}/bin/nemoclaw";
          meta.description = "Run the NemoClaw CLI";
        };
      });

      nixosModules = {
        default = self.nixosModules.nemoclaw;
        nemoclaw = import ./nix/module.nix { inherit self; };
        vllm = {
          imports = [ ./nix/vllm-module.nix ];
          nixpkgs.overlays = [ self.overlays.default ];
        };
        nixclaw = {
          imports = [
            ./nix/vllm-module.nix
            ./nix/nixclaw-module.nix
          ];
          nixpkgs.overlays = [ self.overlays.default ];
        };
      };

      checks = forAllSystems (
        system:
        let
          pkgs = pkgsFor system;
          moduleEvaluation = nixpkgs.lib.nixosSystem {
            system = "aarch64-linux";
            modules = [
              dgx-spark.nixosModules.dgx-spark
              self.nixosModules.nemoclaw
              {
                nixpkgs.config.allowUnfree = true;
                hardware.dgx-spark.enable = true;
                programs.nemoclaw = {
                  enable = true;
                  users = [ "tester" ];
                };
                users.users.tester = {
                  isNormalUser = true;
                  group = "users";
                };
                users.groups.users = { };
                boot.loader.grub.devices = [ "nodev" ];
                fileSystems."/" = {
                  device = "/dev/disk/by-label/nixos";
                  fsType = "ext4";
                };
                system.stateVersion = "25.11";
              }
            ];
          };
          cfg = moduleEvaluation.config;
          vllmModuleEvaluation = nixpkgs.lib.nixosSystem {
            inherit system;
            modules = [
              self.nixosModules.vllm
              {
                nixpkgs.config.allowUnfree = true;

                services.nemoclawVllm = {
                  enable = true;
                  model = "example/model";
                  activeProfile = "agent";
                  profiles.agent = {
                    gpuMemoryUtilization = 0.8;
                    maxModelLen = 32768;
                    maxNumSeqs = 4;
                    maxNumBatchedTokens = 8192;
                    enablePrefixCaching = true;
                    enableChunkedPrefill = true;
                    toolCallParser = "example_parser";
                    environment.VLLM_TEST_PROFILE = "agent";
                  };
                };
                system.stateVersion = "25.11";
              }
            ];
          };
          vllmCfg = vllmModuleEvaluation.config;
          nixclawModuleEvaluation = nixpkgs.lib.nixosSystem {
            inherit system;
            modules = [
              self.nixosModules.nixclaw
              {
                nixpkgs.config.allowUnfree = true;
                networking.hostName = "nixclaw-test";
                services.nemoclawVllm = {
                  enable = true;
                  model = "example/model";
                  profiles.baseline.maxModelLen = 4096;
                };
                services.nixclaw = {
                  enable = true;
                  source = ./.;
                  configurationName = "nixclaw-test";
                  facts.gpus = [
                    {
                      model = "test-gpu";
                      count = 1;
                      computeCapability = "0.0";
                      memoryBytes = 0;
                    }
                  ];
                };
                system.stateVersion = "25.11";
              }
            ];
          };
          nixclawCfg = nixclawModuleEvaluation.config;
          vllmStub = pkgs.runCommand "vllm-test" { version = "0.25.1"; } ''
            mkdir -p "$out/bin"
            touch "$out/bin/vllm"
          '';
          mkVllmPrefixCachingEvaluation =
            enablePrefixCaching:
            nixpkgs.lib.nixosSystem {
              inherit system;
              modules = [
                self.nixosModules.vllm
                {
                  services.nemoclawVllm = {
                    enable = true;
                    package = vllmStub;
                    model = "example/model";
                    profiles.baseline.enablePrefixCaching = enablePrefixCaching;
                  };
                  system.stateVersion = "25.11";
                }
              ];
            };
          vllmPrefixCachingEnabledCfg = (mkVllmPrefixCachingEvaluation true).config;
          vllmPrefixCachingDisabledCfg = (mkVllmPrefixCachingEvaluation false).config;
          moduleContract =
            assert cfg.virtualisation.podman.enable;
            assert !cfg.virtualisation.podman.dockerCompat;
            assert !cfg.virtualisation.podman.dockerSocket.enable;
            assert cfg.virtualisation.docker.enable;
            assert cfg.hardware.nvidia-container-toolkit.enable;
            assert builtins.elem "docker" cfg.users.users.tester.extraGroups;
            pkgs.writeText "nemoclaw-module-contract" "ok\n";
          vllmModuleContract =
            assert nixpkgs.lib.getVersion vllmCfg.services.nemoclawVllm.package == "0.25.1";
            assert vllmCfg.services.nemoclawVllm.activeProfile == "agent";
            assert
              vllmCfg.systemd.services.nemoclaw-vllm.serviceConfig.ExecStart
              == "${vllmCfg.services.nemoclawVllm.launcherPackage}/bin/nemoclaw-vllm-serve";
            assert
              vllmCfg.systemd.services.nemoclaw-vllm.environment.VLLM_CACHE_ROOT
              == "/var/cache/nemoclaw-vllm/vllm";
            assert builtins.elem "render" vllmCfg.users.users.nemoclaw-vllm.extraGroups;
            assert builtins.elem "video" vllmCfg.users.users.nemoclaw-vllm.extraGroups;
            assert builtins.elem pkgs.bash vllmCfg.systemd.services.nemoclaw-vllm.path;
            assert !(builtins.elem 8000 vllmCfg.networking.firewall.allowedTCPPorts);
            pkgs.writeText "nemoclaw-vllm-module-contract" "ok\n";
          vllmCudaToolkitContract = pkgs.runCommand "nemoclaw-vllm-cuda-toolkit-contract" { } ''
            test -e ${pkgs.vllm-nemoclaw.cudaToolkit}/include/cublasLt.h
            test -e ${pkgs.vllm-nemoclaw.cudaToolkit}/lib/libcublasLt.so
            touch "$out"
          '';
          vllmSmoke = pkgs.runCommand "nemoclaw-vllm-smoke" { nativeBuildInputs = [ pkgs.vllm-nemoclaw ]; } ''
            python -c 'import vllm; assert vllm.__version__ == "0.25.1"'
            touch "$out"
          '';
          nixclawModuleContract =
            assert nixclawCfg.systemd.services.nixclaw-broker.serviceConfig.User == "nixclaw-broker";
            assert nixclawCfg.systemd.services.nixclaw-activator.serviceConfig.User == "root";
            assert nixclawCfg.services.nixclaw.activator.leaseSeconds == 300;
            assert nixclawCfg.services.nixclaw.activator.maxResultBytes == 2097152;
            assert nixclawCfg.services.nixclaw.health.timeoutSeconds == 120;
            assert !nixclawCfg.systemd.services.nixclaw-activator.serviceConfig.ProtectHome;
            assert !(builtins.elem 8787 nixclawCfg.networking.firewall.allowedTCPPorts);
            pkgs.writeText "nixclaw-module-contract" "ok\n";
          nixclawTests =
            pkgs.runCommand "nixclaw-platform-tests"
              {
                nativeBuildInputs = [ pkgs.python312 ];
                src = ./.;
              }
              ''
                cd "$src"
                export PYTHONDONTWRITEBYTECODE=1
                export PYTHONPATH="$src/src"
                python -m unittest discover -s tests -v
                touch "$out"
              '';
          vllmPrefixCachingFlags = pkgs.runCommand "nemoclaw-vllm-prefix-caching-flags" { } ''
            enabledLauncher=${vllmPrefixCachingEnabledCfg.services.nemoclawVllm.launcherPackage}/bin/nemoclaw-vllm-serve
            disabledLauncher=${vllmPrefixCachingDisabledCfg.services.nemoclawVllm.launcherPackage}/bin/nemoclaw-vllm-serve

            grep -F -- '--enable-prefix-caching' "$enabledLauncher"
            ! grep -F -- '--no-enable-prefix-caching' "$enabledLauncher"
            grep -F -- '--no-enable-prefix-caching' \
              "$disabledLauncher"
            ! grep -F -- '--enable-prefix-caching' "$disabledLauncher"
            touch "$out"
          '';
        in
        {
          inherit
            moduleContract
            nixclawModuleContract
            nixclawTests
            vllmCudaToolkitContract
            vllmModuleContract
            vllmPrefixCachingFlags
            vllmSmoke
            ;
          nixclaw-platform = pkgs.nixclaw-platform;
          package = pkgs.nemoclaw;
          openshell = pkgs.openshell-nemoclaw;
          smoke =
            pkgs.runCommand "nemoclaw-smoke"
              {
                nativeBuildInputs = [
                  pkgs.nemoclaw
                  pkgs.openshell-nemoclaw
                ];
              }
              ''
                nemoclaw --version | grep -F 'v0.0.86'
                nemohermes --version | grep -F 'v0.0.86'
                nemo-deepagents --version | grep -F 'v0.0.86'
                nemoclaw --help >/dev/null
                nemohermes --help >/dev/null
                nemo-deepagents --help >/dev/null
                nemoclaw agents list | grep -F 'openclaw'
                nemoclaw agents list | grep -F 'hermes'
                nemoclaw agents list | grep -F 'langchain-deepagents-code'
                openshell --version | grep -F '0.0.85'
                openshell-gateway --version | grep -F '0.0.85'
                ${pkgs.stdenv.cc.bintools.dynamicLinker} \
                  --library-path ${
                    nixpkgs.lib.makeLibraryPath [
                      pkgs.stdenv.cc.libc
                      pkgs.stdenv.cc.cc.lib
                    ]
                  } \
                  ${pkgs.openshell-nemoclaw}/bin/openshell-sandbox --version | grep -F '0.0.85'
                packageRoot=${pkgs.nemoclaw}/lib/node_modules/nemoclaw
                test -f "$packageRoot/nemoclaw-blueprint/blueprint.yaml"
                test -f "$packageRoot/scripts/install-openshell.sh"
                test -f "$packageRoot/nemoclaw/dist/index.js"
                test -d "$packageRoot/nemoclaw/node_modules"
                test -f "$packageRoot/nemoclaw/package.json"
                test -f "$packageRoot/nemoclaw/package-lock.json"
                test -f "$packageRoot/nemoclaw/tsconfig.json"
                test -f "$packageRoot/nemoclaw/openclaw.plugin.json"
                test -d "$packageRoot/nemoclaw/src"
                test -f "$packageRoot/agents/openclaw/manifest.yaml"
                test -f "$packageRoot/agents/hermes/manifest.yaml"
                test -f "$packageRoot/agents/langchain-deepagents-code/manifest.yaml"
                test -f "$packageRoot/tsconfig.runtime-preloads.json"
                test -f "$packageRoot/src/lib/tool-disclosure.ts"
                test -f "$packageRoot/src/lib/messaging/channels/slack/runtime/slack-channel-guard.ts"
                test -f "$packageRoot/src/lib/messaging/channels/telegram/runtime/telegram-diagnostics.ts"
                touch "$out"
              '';
        }
      );

      formatter = forAllSystems (system: (pkgsFor system).nixfmt);
    };
}
