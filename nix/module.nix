{ self }:
{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.programs.nemoclaw;
in
{
  options.programs.nemoclaw = {
    enable = lib.mkEnableOption "the community NemoClaw package and its Docker runtime";

    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.nemoclaw;
      defaultText = lib.literalExpression "pkgs.nemoclaw";
      description = "NemoClaw package to install.";
    };

    openshellPackage = lib.mkOption {
      type = lib.types.package;
      default = pkgs.openshell-nemoclaw;
      defaultText = lib.literalExpression "pkgs.openshell-nemoclaw";
      description = "OpenShell package matched to this NemoClaw release.";
    };

    users = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [ "alice" ];
      description = "Existing local users to add to the root-equivalent docker group.";
    };
  };

  config = lib.mkIf cfg.enable {
    nixpkgs.overlays = [ self.overlays.default ];

    environment.systemPackages = [
      cfg.package
      cfg.openshellPackage
    ];

    virtualisation.docker.enable = true;
    virtualisation.podman.dockerCompat = lib.mkForce false;
    virtualisation.podman.dockerSocket.enable = lib.mkForce false;

    users.users = lib.genAttrs cfg.users (_user: {
      extraGroups = [ "docker" ];
    });

    assertions = map (user: {
      assertion = config.users.users.${user}.isNormalUser || config.users.users.${user}.isSystemUser;
      message = "programs.nemoclaw.users contains '${user}', but that account is not declared.";
    }) cfg.users;
  };
}
