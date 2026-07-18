{
  lib,
  stdenv,
  fetchurl,
  patchelf,
}:

let
  version = "0.0.85";
  releaseBase = "https://github.com/NVIDIA/OpenShell/releases/download/v${version}";
  assets = {
    x86_64-linux = {
      cli = {
        name = "openshell-x86_64-unknown-linux-musl.tar.gz";
        hash = "sha256-B4+ghvUGgyw9R9mS5hCfJgdL3VWRbOJo5Hw5cUI0Wes=";
      };
      gateway = {
        name = "openshell-gateway-x86_64-unknown-linux-gnu.tar.gz";
        hash = "sha256-cYzJ+UL4hWXKyxPDlxexKNasyNM2IS1C0mJD82qxns4=";
      };
      sandbox = {
        name = "openshell-sandbox-x86_64-unknown-linux-gnu.tar.gz";
        hash = "sha256-lDBvBX2GLNXDSg2qdpJJFzO8XKUop7kvn2L3F/twqb4=";
      };
    };
    aarch64-linux = {
      cli = {
        name = "openshell-aarch64-unknown-linux-musl.tar.gz";
        hash = "sha256-PPNT55lNWDWiM/4GQfmoYHeRkLBU0PkKBMiXvngnNLg=";
      };
      gateway = {
        name = "openshell-gateway-aarch64-unknown-linux-gnu.tar.gz";
        hash = "sha256-CfKCP26cX3D0SCsgAgbqxFXXiWGNpOvkrP8ELXlOcWI=";
      };
      sandbox = {
        name = "openshell-sandbox-aarch64-unknown-linux-gnu.tar.gz";
        hash = "sha256-LFKylxrs8SXkHtFg2NLyrd8EAxkGyojxIK49Q23WuPc=";
      };
    };
  };
  platformAssets = assets.${stdenv.hostPlatform.system};
  sandboxInterpreter =
    {
      x86_64-linux = "/lib64/ld-linux-x86-64.so.2";
      aarch64-linux = "/lib/ld-linux-aarch64.so.1";
    }
    .${stdenv.hostPlatform.system};
  fetchAsset =
    asset:
    fetchurl {
      url = "${releaseBase}/${asset.name}";
      inherit (asset) hash;
    };
in
stdenv.mkDerivation {
  pname = "openshell-nemoclaw";
  inherit version;
  dontUnpack = true;

  nativeBuildInputs = [ patchelf ];

  installPhase = ''
    runHook preInstall
    mkdir -p "$out/bin"
    tar -xzf ${fetchAsset platformAssets.cli} -C "$out/bin"
    tar -xzf ${fetchAsset platformAssets.gateway} -C "$out/bin"
    tar -xzf ${fetchAsset platformAssets.sandbox} -C "$out/bin"
    chmod 0755 "$out/bin/openshell" "$out/bin/openshell-gateway" "$out/bin/openshell-sandbox"
    patchelf \
      --set-interpreter ${stdenv.cc.bintools.dynamicLinker} \
      --set-rpath ${lib.makeLibraryPath [ stdenv.cc.libc ]} \
      "$out/bin/openshell-gateway"
    runHook postInstall
  '';

  doInstallCheck = true;
  installCheckPhase = ''
    "$out/bin/openshell" --version | grep -F '${version}'
    "$out/bin/openshell-gateway" --version | grep -F '${version}'
    ${stdenv.cc.bintools.dynamicLinker} \
      --library-path ${
        lib.makeLibraryPath [
          stdenv.cc.libc
          stdenv.cc.cc.lib
        ]
      } \
      "$out/bin/openshell-sandbox" --version | grep -F '${version}'
    test "$(patchelf --print-interpreter "$out/bin/openshell-gateway")" = '${stdenv.cc.bintools.dynamicLinker}'
    test "$(patchelf --print-interpreter "$out/bin/openshell-sandbox")" = '${sandboxInterpreter}'
  '';

  meta = {
    description = "OpenShell release pinned for NemoClaw 0.0.86";
    homepage = "https://github.com/NVIDIA/OpenShell";
    license = lib.licenses.asl20;
    platforms = builtins.attrNames assets;
    mainProgram = "openshell";
  };
}
