# NemoClaw Nix flake

Community-maintained Nix packages and a NixOS module for
[NVIDIA NemoClaw](https://github.com/NVIDIA/NemoClaw). This repository is not an
officially supported NemoClaw installation path. NixOS remains outside
NemoClaw's validated platform matrix.

The flake pins NemoClaw `v0.0.86`, the exact OpenShell `v0.0.85` CLI, gateway,
and sandbox binaries required by that release, and a Python 3.12 vLLM `0.25.1`
environment. It supports `aarch64-linux` and `x86_64-linux`. The pinned Hermes
manifest expects Hermes `0.18.0` inside the sandbox.

Current validation is asymmetric. The aarch64 vLLM output built and served
`Qwen/Qwen2.5-0.5B-Instruct` natively on a physical DGX Spark GB10 (compute
capability 12.1). Health, model-list, and OpenAI-compatible chat requests all
returned HTTP 200; warm eager-mode requests generated about 106 tokens/s. The
combined `nixos-dgx-spark` module configuration evaluates, but was not activated
during that package test. The vLLM environment also builds and serves the same
model on x86_64 with an RTX 5060 Ti. An `x86_64-linux` host completed live
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

The flake exports `nemoclaw`, `openshell`, and `vllm` packages. The NemoClaw
wrapper puts its matched OpenShell binaries and required host tools on `PATH`;
it does not download or replace OpenShell during onboarding. The package alone
does not configure a container daemon: when using it without the NixOS module,
provide a real Docker daemon and grant the invoking account access to it.

Hermes sandbox builds also include the flake-pinned NixClaw client at
`/usr/local/bin/nixclaw-agent`. Its source is baked into the immutable image
and uses Hermes' pinned Python environment; missing pure-Python CLI dependencies
are vendored from the pinned Nixpkgs input. Deployment does not mutate the Spark
or sandbox with `pip`.

The vLLM output is generated from [`vllm/uv.lock`](vllm/uv.lock), including its
Python, PyTorch, and CUDA-wheel dependency graph:

```console
nix build github:benthecarman/nemoclaw-nix#vllm
result/bin/python -c 'import vllm; print(vllm.__version__)'
```

`libcuda.so.1` deliberately remains a runtime dependency of the host NVIDIA
driver. A successful package build or import is not evidence that a model can
serve on a particular GPU. On SM121, FlashInfer compiles missing architecture-
specific kernels on first startup. The package therefore includes a pinned Nix
CUDA 13.0 JIT toolchain (nvcc, headers, compiler, and Ninja) while continuing to
use the host driver at runtime. See the
[Spark qualification record](docs/spark-vllm-qualification.md).

## Declarative vLLM service

The `nixosModules.vllm` module turns a named serving profile into an immutable
launcher and systemd service. It accepts any model identifier or local model
path supported by vLLM; the package is model-agnostic.

```nix
{
  imports = [ nemoclaw-nix.nixosModules.vllm ];

  # Required by the NVIDIA CUDA compiler packages used for native GPU kernels.
  nixpkgs.config.allowUnfree = true;

  services.nemoclawVllm = {
    enable = true;
    model = "your-org/your-model";
    servedModelName = "local-agent-model";
    activeProfile = "balanced";

    profiles = {
      baseline = { };
      balanced = {
        gpuMemoryUtilization = 0.82;
        maxModelLen = 32768;
        maxNumSeqs = 4;
        maxNumBatchedTokens = 8192;
        enablePrefixCaching = true;
        enableChunkedPrefill = true;
      };
    };
  };
}
```

The module does not open port `8000` in the host firewall. It runs under a
dedicated account, keeps caches and model state outside the Nix store, supports
root-managed secret environment files, and renders profile arguments into a
read-only store path. Extra `fixedArgs` are intentionally administrator-owned:
an optimizing agent should propose a Nix profile change for review rather than
mutating the running command line.

Useful checks after a rebuild:

```console
systemctl status nemoclaw-vllm
journalctl -u nemoclaw-vllm -f
curl http://127.0.0.1:8000/v1/models
```

## Controlled NixOS improvement platform

The `nixosModules.nixclaw` module adds the Person 1 platform described in
[`HACKATHON_PLAN.md`](HACKATHON_PLAN.md): an unprivileged candidate-building
broker and a root-only generation activator. Their contract follows the
versioned schemas in [`schemas/nixclaw/v1`](schemas/nixclaw/v1) and the agreed
[v1 API issue](https://github.com/benthecarman/nemoclaw-nix/issues/1).

```nix
{
  imports = [ nemoclaw-nix.nixosModules.nixclaw ];

  services.nemoclawVllm = {
    enable = true;
    model = "your-org/your-model";
  };

  services.nixclaw = {
    enable = true;
    source = ./.;
    configurationName = "spark-01";
    facts.gpus = [{
      model = "NVIDIA GB10";
      count = 1;
      computeCapability = "12.1";
      memoryBytes = 0; # Replace with the measured byte count.
    }];
  };
}
```

The broker listens only on loopback by default and exposes versioned facts,
configuration, experiment, and reviewed-proposal routes. Every response uses a
`schemaVersion`/`requestId` envelope. Automatic experiments require a UUID
`Idempotency-Key`, the same `clientRequestId` in the request, the current opaque
base generation, a configured workload ID, and only fields advertised by
`GET /v1/config`. The broker builds candidates but has no activation interface.

The activator listens only on `/run/nixclaw/activator.sock`. Add trusted human
operators to the configured `nixclaw-operators` group, then use:

```console
nixclawctl review <experiment-uuid>
nixclawctl approve <experiment-uuid>
nixclawctl record-results <experiment-uuid> \
  --baseline baseline.json \
  --candidate candidate.json \
  --decision decision.json
nixclawctl confirm <experiment-uuid>
nixclawctl rollback <experiment-uuid>
```

Approval activates workers before the head, runs the declared systemd and HTTP
health checks, and starts a five-minute lease. An activation failure or expired
lease restores the recorded generations in reverse order. Confirmation checks
health again and makes the candidate the boot generation. Confirmation also
requires operator-attached benchmark results with an accepted decision. The
activator verifies that their workload, environment, generations, profile
hashes, metric summaries, and decision gates match the reviewed experiment.

Replica deployments mark nodes as `baseline` or `canary`. An experiment drains
and changes only its explicit canary targets. Benchmark results identify the
stable and canary nodes, and confirmation promotes an accepted generation to
the baseline replicas before restoring normal routing. A rejected, failed, or
expired experiment restores the canary without disturbing the baseline.

Reviewed proposals accept unified diffs up to 64 KiB and only paths listed in
`services.nixclaw.broker.editablePaths`. The host flake must already import
those files; the default is `nixclaw/agent-managed.nix`. Binary patches,
traversal, symlink targets, flake/lock changes, and protected NixOS options are
rejected. Keep the source clean and immutable for deployment, provision bearer
tokens outside the Nix store, and test on a canary before adding remote nodes.

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
