{
  lib,
  buildPythonApplication,
  makeWrapper,
  setuptools,
  nix,
  patch,
  openssh,
  curl,
  systemd,
  coreutils,
}:

buildPythonApplication {
  pname = "nixclaw-platform";
  version = "0.1.0";
  src = lib.cleanSource ../.;
  pyproject = true;
  build-system = [ setuptools ];
  nativeBuildInputs = [ makeWrapper ];
  pythonImportsCheck = [
    "nixclaw_platform.broker"
    "nixclaw_platform.activator"
  ];
  postInstall = ''
    mkdir -p "$out/share/nixclaw"
    cp -r schemas "$out/share/nixclaw/schemas"
    for program in nixclaw-broker nixclaw-activator; do
      wrapProgram "$out/bin/$program" --prefix PATH : ${
        lib.makeBinPath [
          nix
          patch
          openssh
          curl
          systemd
          coreutils
        ]
      }
    done
  '';
  meta = {
    description = "NixClaw constrained NixOS candidate builder and activator";
    license = lib.licenses.mit;
    platforms = lib.platforms.linux;
  };
}
