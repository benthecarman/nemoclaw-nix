# DGX Spark native vLLM qualification

This record captures the first physical DGX Spark test of this flake's native
vLLM package. It is a package and GPU-serving qualification, not a NixOS
generation activation or a completed NemoClaw/OpenShell integration test.

## Target and package

- Architecture: `aarch64-linux`
- GPU: NVIDIA GB10, compute capability 12.1
- NVIDIA driver: 610.43.03
- Kernel: 6.18.38
- vLLM: 0.25.1
- PyTorch: 2.11.0
- JIT toolkit: Nix CUDA 13.0
- Model: `Qwen/Qwen2.5-0.5B-Instruct`

The exact dirty local source tree was staged under `/tmp` on the Spark and built
with `nix build path:.#vllm --no-link`. No NixOS generation was switched and no
system service was installed.

## GPU and serving checks

The packaged Python environment reported:

```text
vllm 0.25.1
cuda_available True
cuda_devices 1
device NVIDIA GB10
capability (12, 1)
arch_list ['sm_80', 'sm_90', 'sm_100', 'sm_110', 'sm_120']
```

A 2048 by 2048 CUDA matrix multiplication completed before model serving. The
server was then started on loopback with conservative qualification settings:

```console
vllm serve Qwen/Qwen2.5-0.5B-Instruct \
  --host 127.0.0.1 \
  --port 18081 \
  --served-model-name spark-smoke \
  --max-model-len 2048 \
  --gpu-memory-utilization 0.20 \
  --enforce-eager
```

FlashInfer had no precompiled sampling cubin for the Spark's `sm_121a` target,
so first startup compiled and linked the sampling extension with the packaged
Nix CUDA toolchain. Engine initialization, including profiling, KV-cache
creation, SM121 JIT, and warmup, took 195.34 seconds. The generated extension is
stored in the runtime cache for reuse.

The service allocated roughly 23.5 GiB for KV cache and exposed the expected
OpenAI-compatible routes. `/health`, `/v1/models`, and
`/v1/chat/completions` each returned HTTP 200.

Three warm completion requests took 1.207, 1.205, and 1.203 seconds. The latter
two each produced 128 completion tokens, or approximately 106 tokens/s
end-to-end. This is a smoke-test number from eager mode, not an optimized Spark
benchmark.

## Packaging findings incorporated

The test identified host assumptions that ordinary imports do not exercise.
The package wrapper now provides:

- `TRITON_LIBCUDA_PATH` for the NixOS driver location;
- pinned C and C++ compilers for Triton and extension JIT;
- a composed CUDA 13.0 `CUDA_HOME` with nvcc, CUDA runtime and CRT headers,
  CCCL, and cuRAND development outputs;
- Ninja and linker search paths for the Nix CUDA and host driver layouts; and
- a `lib64` compatibility view required by FlashInfer's build generator.

The NixOS service account also belongs to the `render` and `video` groups so it
can open GPU device nodes after the module is activated.

## Remaining acceptance work

- Activate and test the `services.nemoclawVllm` systemd module on a canary
  Spark.
- Test the non-eager/CUDA-graph profile and record optimized throughput,
  latency, power, and cold/warm startup time.
- Qualify the intended hackathon model and context size; the 0.5B model only
  proves the serving path.
- Connect NemoClaw/OpenShell to the native endpoint and test the policy boundary
  end to end.
- Decide how SM121 JIT caches are preserved or prewarmed across immutable NixOS
  deployments.

The temporary server was stopped cleanly after testing, and the Spark's active
NixOS generation was left unchanged.
