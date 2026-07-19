{
  lib,
  buildNpmPackage,
  nodejs_22,
  makeWrapper,
  docker-client,
  bash,
  binutils,
  coreutils,
  curl,
  git,
  gnugrep,
  gnused,
  gnutar,
  gzip,
  iproute2,
  netcat-openbsd,
  openssh,
  procps,
  util-linux,
  zstd,
  src,
  nixclaw-src,
  openshell,
}:

let
  version = "0.0.86";

  plugin = buildNpmPackage {
    pname = "nemoclaw-plugin";
    inherit version;
    src = "${src}/nemoclaw";
    nodejs = nodejs_22;
    npmDepsHash = "sha256-ayArSsDNgFxCE5DCVc1/p7IFZxRcuBeea5oKkhAYHKY=";
    npmBuildScript = "build";
    npmInstallFlags = [ "--ignore-scripts" ];
    npmRebuildFlags = [ "--ignore-scripts" ];
    npmPruneFlags = [ "--ignore-scripts" ];
  };

  runtimePath = lib.makeBinPath [
    nodejs_22
    openshell
    docker-client
    bash
    binutils
    coreutils
    curl
    git
    gnugrep
    gnused
    gnutar
    gzip
    iproute2
    netcat-openbsd
    openssh
    procps
    util-linux
    zstd
  ];

  removeDevelopmentAgent = ''
    ${nodejs_22}/bin/node <<'NODE'
    const fs = require("node:fs");
    const dependency = "@earendil-works/pi-coding-agent";
    const packageJson = JSON.parse(fs.readFileSync("package.json", "utf8"));
    delete packageJson.devDependencies?.[dependency];
    fs.writeFileSync("package.json", JSON.stringify(packageJson, null, 2) + "\n");

    const lock = JSON.parse(fs.readFileSync("package-lock.json", "utf8"));
    delete lock.packages[""]?.devDependencies?.[dependency];
    for (const key of Object.keys(lock.packages)) {
      if (key === "node_modules/" + dependency || key.startsWith("node_modules/" + dependency + "/")) {
        delete lock.packages[key];
      }
    }
    fs.writeFileSync("package-lock.json", JSON.stringify(lock, null, 2) + "\n");
    NODE
    substituteInPlace src/lib/agent/base-image.ts \
      --replace-fail \
        'const stagedDockerfile = path.join(buildCtx, "Dockerfile");' \
        'const stagedDockerfile = path.join(buildCtx, "Dockerfile"); fs.chmodSync(stagedDockerfile, 0o644);'
    substituteInPlace src/lib/agent/base-image.ts \
      --replace-fail \
        'fs.copyFileSync(agentDockerfile, stagedDockerfile);' \
        'fs.copyFileSync(agentDockerfile, stagedDockerfile); fs.chmodSync(stagedDockerfile, 0o644);'
    printf '%s\n' '${version}' > .version
  '';
in
buildNpmPackage {
  pname = "nemoclaw";
  inherit version src;
  nodejs = nodejs_22;
  npmDepsHash = "sha256-5BOCrpN3fPSYtHLAPpD880PWfvPZ5dRRTOJpvGQ8zpE=";
  npmBuildScript = "build:cli";
  npmInstallFlags = [ "--ignore-scripts" ];
  npmRebuildFlags = [ "--ignore-scripts" ];
  npmPruneFlags = [ "--ignore-scripts" ];
  nativeBuildInputs = [ makeWrapper ];
  postPatch = removeDevelopmentAgent;

  postInstall = ''
    packageRoot="$out/lib/node_modules/nemoclaw"
    pluginRoot="${plugin}/lib/node_modules/nemoclaw"

    # The upstream source installer runs from a checkout, while npm's `files`
    # list omits resources that the runtime resolves relative to its root.
    # Restore that checkout layout explicitly for agent discovery and sandbox
    # build-context staging.
    cp -r ${src}/agents "$packageRoot/agents"
    cp ${src}/tsconfig.runtime-preloads.json "$packageRoot/tsconfig.runtime-preloads.json"
    rm -rf "$packageRoot/src"
    cp -r ${src}/src "$packageRoot/src"

    chmod u+w "$packageRoot/agents/hermes/policy-additions.yaml"
    cat ${./hermes-nixclaw-policy.yaml} \
      >> "$packageRoot/agents/hermes/policy-additions.yaml"

    # Bake the Nix-pinned NixClaw client into Hermes' immutable image rather
    # than mutating the Spark or sandbox with pip.
    mkdir -p "$packageRoot/nixclaw"
    cp -r ${nixclaw-src}/src "$packageRoot/nixclaw/src"
    install -m 0755 ${./nixclaw-agent} "$packageRoot/nixclaw/nixclaw-agent"
    hermesNixclawMarker='ENV HERMES_TUI_DIR="/opt/hermes/ui-tui"'
    test "$(grep -Fxc "$hermesNixclawMarker" \
      "$packageRoot/agents/hermes/Dockerfile")" -eq 1
    chmod u+w "$packageRoot/agents/hermes" \
      "$packageRoot/agents/hermes/Dockerfile"
    sed -i "\\|^$hermesNixclawMarker$|r ${./hermes-nixclaw.dockerfile}" \
      "$packageRoot/agents/hermes/Dockerfile"

    rm -rf "$packageRoot/nemoclaw"
    mkdir -p "$packageRoot/nemoclaw"
    cp ${src}/nemoclaw/package.json "$packageRoot/nemoclaw/package.json"
    cp ${src}/nemoclaw/package-lock.json "$packageRoot/nemoclaw/package-lock.json"
    cp ${src}/nemoclaw/tsconfig.json "$packageRoot/nemoclaw/tsconfig.json"
    cp ${src}/nemoclaw/openclaw.plugin.json "$packageRoot/nemoclaw/openclaw.plugin.json"
    cp -r ${src}/nemoclaw/src "$packageRoot/nemoclaw/src"
    cp -r "$pluginRoot/dist" "$packageRoot/nemoclaw/dist"
    cp -r "$pluginRoot/node_modules" "$packageRoot/nemoclaw/node_modules"

    test "$(grep -o -F 'chmodSync(stagedDockerfile, 0o644)' \
      "$packageRoot/dist/lib/agent/base-image.js" | wc -l)" -eq 2

    for command in nemoclaw nemohermes nemo-deepagents; do
      wrapProgram "$out/bin/$command" \
        --prefix PATH : ${runtimePath} \
        --set NEMOCLAW_OPENSHELL_BIN ${openshell}/bin/openshell \
        --set NEMOCLAW_OPENSHELL_GATEWAY_BIN ${openshell}/bin/openshell-gateway \
        --set NEMOCLAW_OPENSHELL_SANDBOX_BIN ${openshell}/bin/openshell-sandbox
    done
  '';

  meta = {
    description = "Community Nix package for NVIDIA NemoClaw";
    homepage = "https://github.com/NVIDIA/NemoClaw";
    license = lib.licenses.asl20;
    platforms = [
      "aarch64-linux"
      "x86_64-linux"
    ];
    mainProgram = "nemoclaw";
  };
}
