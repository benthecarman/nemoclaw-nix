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
  };

  outputs =
    inputs@{
      self,
      nixpkgs,
      nemoclaw-src,
      dgx-spark,
      ...
    }:
    let
      supportedSystems = [
        "aarch64-linux"
        "x86_64-linux"
      ];
      forAllSystems = nixpkgs.lib.genAttrs supportedSystems;
      overlay = final: _prev: rec {
        openshell-nemoclaw = final.callPackage ./nix/openshell.nix { };
        nemoclaw = final.callPackage ./nix/nemoclaw.nix {
          src = nemoclaw-src;
          openshell = openshell-nemoclaw;
        };
      };
      pkgsFor =
        system:
        import nixpkgs {
          inherit system;
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
          moduleContract =
            assert cfg.virtualisation.podman.enable;
            assert !cfg.virtualisation.podman.dockerCompat;
            assert !cfg.virtualisation.podman.dockerSocket.enable;
            assert cfg.virtualisation.docker.enable;
            assert cfg.hardware.nvidia-container-toolkit.enable;
            assert builtins.elem "docker" cfg.users.users.tester.extraGroups;
            pkgs.writeText "nemoclaw-module-contract" "ok\n";
        in
        {
          inherit moduleContract;
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
