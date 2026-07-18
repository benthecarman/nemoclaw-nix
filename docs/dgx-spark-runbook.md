# DGX Spark deployment runbook

This runbook installs the community NemoClaw Nix package on a DGX Spark running
NixOS. It uses Hermes, keeps native Podman for existing Spark workflows, and
gives NemoClaw a real Docker daemon. NixOS is not in NemoClaw's validated
platform matrix, so qualify one canary Spark before rolling the configuration
out to the rest of the fleet.

At this revision, the ARM64 derivations and combined NixOS module configuration
have been evaluated but not built or run on DGX Spark hardware. Live validation
was completed on `x86_64-linux` with NemoClaw `0.0.86`, OpenShell `0.0.85`,
OpenClaw `2026.6.10`, a Ready sandbox, and healthy local vLLM. The hardware
steps and Hermes runtime checks below are the remaining acceptance work. The
prior OpenClaw result verifies shared packaging only; it is not a Hermes test or
a claim of canonical or supported NemoClaw behavior.

The examples use `spark-01` and an operator account named `operator`. Replace
those values on every machine. Never reuse another machine's generated
`hardware-configuration.nix`, filesystem UUIDs, hostname, host keys, or secrets.

## 1. Finish the base installation

Before replacing DGX OS, update the Spark firmware while DGX OS can still boot
and disable Secure Boot. The `nixos-dgx-spark` project warns that factory
firmware may not boot NixOS. Use its DGX Spark image and installation procedure,
then generate a hardware configuration for each physical machine.

After the first boot, confirm that the machine is ARM64 and has its expected
storage and network identity:

```console
uname -m
findmnt /
ip -brief address
```

Expected architecture: `aarch64`.

## 2. Add the flake inputs

Keep the system configuration in a Git repository so the same reviewed
`flake.lock` can be deployed to every Spark. A minimal `flake.nix` is:

```nix
{
  description = "DGX Spark fleet configuration";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    dgx-spark = {
      url = "github:graham33/nixos-dgx-spark";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    nemoclaw-nix = {
      url = "github:benthecarman/nemoclaw-nix";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.dgx-spark.follows = "dgx-spark";
    };
  };

  outputs =
    {
      nixpkgs,
      dgx-spark,
      nemoclaw-nix,
      ...
    }:
    {
      nixosConfigurations.spark-01 = nixpkgs.lib.nixosSystem {
        system = "aarch64-linux";
        modules = [
          ./hosts/spark-01/hardware-configuration.nix
          ./hosts/spark-01/configuration.nix
          dgx-spark.nixosModules.dgx-spark
          nemoclaw-nix.nixosModules.nemoclaw
        ];
      };
    };
}
```

Use the configuration name as the deployment target, such as `spark-01` above.
Give every additional Spark its own `nixosConfigurations.<hostname>` entry and
`hosts/<hostname>/hardware-configuration.nix`; never import one host's generated
hardware configuration into another host.

Create and review one shared lock before deploying the canary:

```console
nix flake lock
nix flake check --all-systems --no-build
git add flake.nix flake.lock hosts/
git commit -m "lock DGX Spark canary"
```

Deploy that exact commit and `flake.lock` to the canary. Do not refresh an input
between canary acceptance and fleet rollout.

## 3. Configure the host

Add the following to `hosts/spark-01/configuration.nix`, merging it with the
bootloader, filesystems, locale, and other settings created during installation:

```nix
{ pkgs, ... }:

{
  hardware.dgx-spark.enable = true;

  networking.hostName = "spark-01";
  networking.networkmanager.enable = true;

  services.openssh = {
    enable = true;
    settings.PermitRootLogin = "no";
  };

  users.users.operator = {
    isNormalUser = true;
    extraGroups = [
      "wheel"
      "networkmanager"
      "video"
    ];
    openssh.authorizedKeys.keys = [
      "<OPERATOR_SSH_PUBLIC_KEY>"
    ];
  };

  programs.nemoclaw = {
    enable = true;
    users = [ "operator" ];
  };

  nix.settings = {
    experimental-features = [
      "nix-command"
      "flakes"
    ];
    trusted-users = [
      "root"
      "operator"
    ];
  };

  environment.systemPackages = with pkgs; [
    curl
    git
    jq
    nvidia-container-toolkit
  ];

  # Keep the value generated for the NixOS release used during installation.
  system.stateVersion = "25.11";
}
```

`programs.nemoclaw.users` adds only those explicitly listed accounts to the
`docker` group. Docker group membership grants root-equivalent control of the
host daemon, so use a trusted operator account and never add untrusted users.
Podman remains installed and usable through the explicit `podman` command.

Build the configuration before activating it:

```console
sudo nixos-rebuild build --flake /etc/nixos#spark-01
```

For the first deployment, make the new kernel the next boot generation and
reboot:

```console
sudo nixos-rebuild boot --flake /etc/nixos#spark-01
sudo reboot
```

After reconnecting, start a new login shell so `operator` receives its Docker
group membership.

## 4. Verify the host boundary

Do not start Hermes onboarding until every command in this section succeeds.

Confirm the Spark kernel and GPU:

```console
uname -m
uname -r
nvidia-smi
```

Confirm that both engines are available and the Docker-compatible surface
belongs to Docker rather than Podman:

```console
systemctl is-active docker
docker version --format '{{.Server.Platform.Name}} {{.Server.Version}}'
podman version
readlink -f "$(command -v docker)"
stat -c '%U:%G %a %n' /run/docker.sock
```

Expected results:

- Docker is active and reports a server version.
- `docker` resolves to the Docker client, not a Podman compatibility wrapper.
- `/run/docker.sock` is the real Docker socket.
- `podman version` still works independently.

Confirm that NVIDIA CDI devices exist and Docker can use them:

```console
nvidia-ctk cdi list
docker run --rm --device nvidia.com/gpu=all \
  nvidia/cuda:12.8.0-base-ubuntu24.04 nvidia-smi
```

The CDI list must include `nvidia.com/gpu` devices, and the container probe must
show the Spark GPU. Repair CDI or the Docker/NVIDIA runtime before proceeding if
either check fails.

Finally, verify the pinned application pair:

```console
nemohermes --version
openshell --version
openshell-gateway --version
```

Expected versions for the current lock are NemoHermes `0.0.86` and OpenShell
`0.0.85`. This is the host CLI version; the Hermes agent version is checked
inside the sandbox after onboarding.

## 5. Run the canary onboarding

Run the first onboarding as the trusted operator, without `sudo`:

```console
nemohermes onboard
```

For the canary:

1. Start with a hosted inference provider to validate packaging, Docker,
   OpenShell, policy application, and the sandbox independently of a local
   model server. Hermes Provider is also available if that is the intended
   hosted route.
2. Use a unique sandbox name such as `spark-01-hermes-canary`.
3. Leave messaging and Tavily web search disabled for the first pass.
4. Use the Balanced policy tier unless the deployment has a reviewed reason to
   use another tier.

Enter credentials only into NemoClaw's interactive credential prompt. Never put
API keys or tokens in a Nix expression, Git repository, command argument, or
chat message.

Onboarding performs large image downloads and may take several minutes. Do not
start a second onboarding process while the first is running.

## 6. Verify the canary sandbox

Use the sandbox name selected during onboarding:

```console
nemohermes spark-01-hermes-canary status
```

The required result is a `Ready` sandbox with healthy runtime and
`inference.local` checks. Confirm the in-sandbox Hermes version:

```console
nemohermes spark-01-hermes-canary exec -- hermes --version
```

For the current lock, expect Hermes `0.18.0`. Confirm the host forwards and API
health:

```console
nemohermes spark-01-hermes-canary dashboard-url --quiet
curl -fsS http://127.0.0.1:8642/health
```

With the default forwards, the first command prints
`http://127.0.0.1:18789/`; the second checks the separate Hermes API relay on
port `8642`.

Then connect and send one short prompt:

```console
nemohermes spark-01-hermes-canary connect
```

Inside the sandbox, run `hermes` and confirm that the selected model responds.
For remote access, forward Hermes dashboard port `18789` or API port `8642`
over SSH from the workstation. Do not expose either port directly to the LAN.
Hermes handles its own dashboard and API authentication; do not append an
OpenClaw dashboard token fragment to either URL.

If verification fails, collect the status and logs before retrying:

```console
nemohermes spark-01-hermes-canary status
nemohermes spark-01-hermes-canary logs --follow
```

Use `nemohermes onboard --resume` after correcting the reported condition so a
healthy completed step is not rebuilt unnecessarily.

## 7. Add local vLLM after the canary passes

NemoClaw can start its managed vLLM path on a detected DGX Spark or connect to an
existing vLLM server. The upstream recipe has not been qualified through this
NixOS flake on physical Spark hardware. Use the current model choices printed by
onboarding rather than copying an old model slug into the Nix configuration.

For an existing server, NemoClaw detects vLLM at
`http://localhost:8000/v1`. The endpoint must also be reachable from the
OpenShell Docker gateway. Restrict unauthenticated port `8000` to loopback and
the required Docker bridge; do not expose it to the LAN or internet. A server
on another port needs an operator-managed, narrowly scoped forwarder to port
`8000`.

Verify the server before onboarding:

```console
curl -fsS http://127.0.0.1:8000/v1/models | jq .
```

Then create a separate Hermes sandbox and select Local vLLM, or select the
managed vLLM option to let NemoClaw use its current DGX Spark recipe. `--fresh`
starts a new onboarding session rather than trying to resume the completed
hosted-provider canary:

```console
nemohermes onboard --fresh --name spark-01-hermes-vllm
```

Afterward, repeat the named status check and a short Hermes request. Watch
unified-memory use while qualifying local inference, and do not simultaneously
run unrelated GPU-heavy Podman workloads.

## 8. Roll out to the remaining Sparks

After the canary passes:

1. Record the exact canary Git revision and keep its `flake.lock` unchanged.
2. Give each Spark a unique hostname, hardware configuration, SSH identity, and
   sandbox name.
3. Deploy the same reviewed revision and run `nixos-rebuild build` on each target
   before activation.
4. Deploy one additional Spark at a time and repeat the host-boundary and
   sandbox status checks.
5. Stop the rollout if the kernel, CDI, Docker, OpenShell, Hermes, or inference
   results differ from the canary.

To return a machine to its previous NixOS generation after a bad system
activation:

```console
sudo nixos-rebuild switch --rollback
```

For a kernel or boot failure, select the prior generation from the boot menu.
System-generation rollback does not delete or downgrade Docker images,
containers, model caches, or NemoClaw sandbox state. After rollback, use the
previous generation's compatible CLI to inspect the named sandbox before
resuming the rollout.
