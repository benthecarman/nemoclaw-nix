# NemoClaw Nix flake

Community-maintained Nix packages and a NixOS module for
[NVIDIA NemoClaw](https://github.com/NVIDIA/NemoClaw). This repository is not an
officially supported NemoClaw installation path. NixOS remains outside
NemoClaw's validated platform matrix.

The flake pins NemoClaw `v0.0.86` together with the exact OpenShell `v0.0.85`
CLI, gateway, and sandbox binaries required by that release. It supports
`aarch64-linux` and `x86_64-linux`. The pinned Hermes manifest expects Hermes
`0.18.0` inside the sandbox.

Current validation is asymmetric. The ARM64 derivations and the combined
`nixos-dgx-spark` module configuration evaluate successfully, but have not been
built or run on a physical DGX Spark. An `x86_64-linux` host completed live
OpenClaw onboarding with a Ready sandbox, NemoClaw `0.0.86`, OpenShell `0.0.85`,
OpenClaw `2026.6.10`, and a healthy local vLLM route. That proves the shared
package, Docker, and OpenShell path, but it is not a live Hermes validation.
Treat the Hermes-focused DGX Spark runbook as a canary qualification procedure,
not as evidence of a supported platform.

## Packages

Run the CLI without installing it:

```console
nix run github:benthecarman/nemoclaw-nix -- --help
```

The flake exports `nemoclaw` and `openshell` packages. The NemoClaw wrapper puts
its matched OpenShell binaries and required host tools on `PATH`; it does not
download or replace OpenShell during onboarding. The package alone does not
configure a container daemon: when using it without the NixOS module, provide a
real Docker daemon and grant the invoking account access to it.

## NixOS with nixos-dgx-spark

`nixos-dgx-spark` enables Podman and normally makes Podman own the `docker`
command and `/run/docker.sock`. NemoClaw rejects that compatibility path. The
module keeps native Podman available while reserving the Docker-compatible
surface for a real Docker daemon:

```nix
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    dgx-spark = {
      url = "github:graham33/nixos-dgx-spark";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    nemoclaw-nix = {
      url = "github:benthecarman/nemoclaw-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { nixpkgs, dgx-spark, nemoclaw-nix, ... }: {
    nixosConfigurations.dgx-spark = nixpkgs.lib.nixosSystem {
      system = "aarch64-linux";
      modules = [
        dgx-spark.nixosModules.dgx-spark
        nemoclaw-nix.nixosModules.nemoclaw
        {
          hardware.dgx-spark.enable = true;
          programs.nemoclaw = {
            enable = true;
            users = [ "your-user" ];
          };
        }
      ];
    };
  };
}
```

After rebuilding and starting a fresh login shell, verify the engine boundary:

```console
podman info
docker info --format '{{.ServerVersion}} {{.Name}}'
readlink -f /run/docker.sock
```

Explicit `podman` commands continue to use Podman. `docker` and
`/run/docker.sock` use Docker for NemoClaw. The engines have independent image,
container, network, and volume stores: neither engine sees resources created by
the other, images used by both consume disk twice, and published host ports can
still conflict. Membership in the `docker` group grants root-equivalent control
over the host daemon; list only trusted local accounts already declared in the
NixOS configuration in `programs.nemoclaw.users`.

The DGX Spark module already enables NVIDIA Container Toolkit. Before onboarding,
confirm that Docker sees the CDI devices and that a GPU container probe succeeds.

For a complete first-boot, deployment, onboarding, verification, and fleet
rollout procedure, see the [DGX Spark runbook](docs/dgx-spark-runbook.md).

## Hermes onboarding

Start with a cloud inference provider so the first validation does not mix host
model-server networking with packaging concerns:

```console
nemohermes onboard
```

Supply credentials interactively or through the documented runtime environment.
Never place API keys in a Nix expression: values written into the Nix store are
world-readable to local users.

### Local x86_64 validation

The `x86_64-linux` output completed a full OpenClaw onboarding flow on a regular
Linux host with a real Docker daemon. Hermes still needs its own live runtime
qualification. For that qualification with an existing local vLLM server,
start the server before onboarding and make it available as
`http://localhost:8000/v1`; that is the endpoint and bundled host-gateway port
NemoClaw detects for the **Local vLLM** choice.

A server listening on another port needs an operator-managed bridge or
forwarder to port `8000`, including reachability from the OpenShell Docker
gateway. Keep that exposure limited to loopback and the OpenShell Docker subnet.
This flake does not create a forwarder or firewall policy, and it does not
reconfigure an existing Ollama service.

Create a separate named sandbox instead of resuming or modifying an earlier
cloud-provider canary:

```console
nemohermes onboard --fresh --name hermes-vllm
```

After onboarding, use `nemohermes hermes-vllm status` to confirm that the sandbox
is ready and the inference route is healthy. This validates the package, Docker
gateway, OpenShell, and Hermes integration; it does not validate DGX Spark
hardware or sandbox GPU passthrough.

## Updating

Treat NemoClaw and OpenShell as one reviewed compatibility pair:

1. Update the `nemoclaw-src` tag.
2. Read its `nemoclaw-blueprint/blueprint.yaml` OpenShell minimum and maximum.
3. Update all OpenShell release assets and hashes when the exact version changes.
4. Refresh both npm dependency hashes.
5. Evaluate every output with `nix flake check --all-systems --no-build`, then
   run the checks for both architectures on native or remote builders.
6. Complete physical DGX Spark acceptance.

Do not independently advance OpenShell beyond NemoClaw's declared maximum.
