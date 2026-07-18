{
  pkgs,
  lib,
  pyproject-nix,
  uv2nix,
  pyproject-build-systems,
  supportedSystems,
}:

let
  workspace = uv2nix.lib.workspace.loadWorkspace {
    workspaceRoot = ../vllm;
  };
  python = pkgs.python312;
  pythonOverlay = workspace.mkPyprojectOverlay {
    sourcePreference = "wheel";
  };
  pythonSet = (pkgs.callPackage pyproject-nix.build.packages { inherit python; }).overrideScope (
    lib.composeManyExtensions [
      pyproject-build-systems.overlays.wheel
      pythonOverlay
      (final: prev: {
        numba = prev.numba.overrideAttrs (old: {
          buildInputs = (old.buildInputs or [ ]) ++ [ pkgs.tbb ];
        });
        pynvvideocodec = prev.pynvvideocodec.overrideAttrs (old: {
          # libcuda is supplied by the host NVIDIA driver at runtime.
          autoPatchelfIgnoreMissingDeps = (old.autoPatchelfIgnoreMissingDeps or [ ]) ++ [
            "libcuda.so.1"
          ];
        });
        tilelang = prev.tilelang.overrideAttrs (old: {
          buildInputs = (old.buildInputs or [ ]) ++ [
            final."apache-tvm-ffi"
            final."z3-solver"
          ];
          preFixup = (old.preFixup or "") + ''
            addAutoPatchelfSearchPath ${final."apache-tvm-ffi"}/lib/python3.12/site-packages/tvm_ffi/lib
            addAutoPatchelfSearchPath ${final."z3-solver"}/lib/python3.12/site-packages/z3/lib
          '';
        });
        torch =
          let
            cudaWheels = [
              final."nvidia-cublas"
              final."nvidia-cuda-cupti"
              final."nvidia-cuda-nvrtc"
              final."nvidia-cuda-runtime"
              final."nvidia-cudnn-cu13"
              final."nvidia-cufft"
              final."nvidia-cufile"
              final."nvidia-curand"
              final."nvidia-cusolver"
              final."nvidia-cusparse"
              final."nvidia-cusparselt-cu13"
              final."nvidia-nccl-cu13"
              final."nvidia-nvshmem-cu13"
            ];
          in
          prev.torch.overrideAttrs (old: {
            buildInputs = (old.buildInputs or [ ]) ++ cudaWheels;
            autoPatchelfIgnoreMissingDeps = (old.autoPatchelfIgnoreMissingDeps or [ ]) ++ [
              "libcuda.so.1"
            ];
            preFixup = (old.preFixup or "") + ''
              ${lib.concatMapStringsSep "\n" (
                package: "addAutoPatchelfSearchPath ${package}/lib/python3.12/site-packages/nvidia/*/lib"
              ) cudaWheels}
            '';
          });
        "torch-c-dlpack-ext" = prev."torch-c-dlpack-ext".overrideAttrs (old: {
          buildInputs = (old.buildInputs or [ ]) ++ [ final.torch ];
          preFixup = (old.preFixup or "") + ''
            addAutoPatchelfSearchPath ${final.torch}/lib/python3.12/site-packages/torch/lib
          '';
        });
        torchaudio = prev.torchaudio.overrideAttrs (old: {
          buildInputs = (old.buildInputs or [ ]) ++ [ final.torch ];
          preFixup = (old.preFixup or "") + ''
            addAutoPatchelfSearchPath ${final.torch}/lib/python3.12/site-packages/torch/lib
          '';
        });
        torchcodec = prev.torchcodec.overrideAttrs (old: {
          buildInputs = (old.buildInputs or [ ]) ++ [
            final.torch
            pkgs.ffmpeg
          ];
          # The wheel carries adapters for several FFmpeg ABIs. Patch the
          # current ABI and leave inactive adapters unresolved.
          autoPatchelfIgnoreMissingDeps = (old.autoPatchelfIgnoreMissingDeps or [ ]) ++ [
            "libav*.so.*"
            "libsw*.so.*"
          ];
          preFixup = (old.preFixup or "") + ''
            addAutoPatchelfSearchPath ${final.torch}/lib/python3.12/site-packages/torch/lib
          '';
        });
        torchvision = prev.torchvision.overrideAttrs (old: {
          buildInputs = (old.buildInputs or [ ]) ++ [ final.torch ];
          preFixup = (old.preFixup or "") + ''
            addAutoPatchelfSearchPath ${final.torch}/lib/python3.12/site-packages/torch/lib
          '';
        });
        "tokenspeed-mla" = prev."tokenspeed-mla".overrideAttrs (old: {
          buildInputs = (old.buildInputs or [ ]) ++ [
            final."apache-tvm-ffi"
            final."nvidia-cutlass-dsl-libs-base"
          ];
          preFixup = (old.preFixup or "") + ''
            addAutoPatchelfSearchPath ${final."apache-tvm-ffi"}/lib/python3.12/site-packages/tvm_ffi/lib
            addAutoPatchelfSearchPath ${
              final."nvidia-cutlass-dsl-libs-base"
            }/lib/python3.12/site-packages/nvidia_cutlass_dsl/lib
          '';
        });
        vllm = prev.vllm.overrideAttrs (old: {
          buildInputs = (old.buildInputs or [ ]) ++ [
            final.torch
            final."nvidia-cuda-nvrtc"
            final."nvidia-cuda-runtime"
          ];
          autoPatchelfIgnoreMissingDeps = (old.autoPatchelfIgnoreMissingDeps or [ ]) ++ [
            "libcuda.so.1"
          ];
          preFixup = (old.preFixup or "") + ''
            addAutoPatchelfSearchPath ${final.torch}/lib/python3.12/site-packages/torch/lib
            addAutoPatchelfSearchPath ${final."nvidia-cuda-nvrtc"}/lib/python3.12/site-packages/nvidia/*/lib
            addAutoPatchelfSearchPath ${final."nvidia-cuda-runtime"}/lib/python3.12/site-packages/nvidia/*/lib
          '';
        });
        xgrammar = prev.xgrammar.overrideAttrs (old: {
          buildInputs = (old.buildInputs or [ ]) ++ [ final."apache-tvm-ffi" ];
          preFixup = (old.preFixup or "") + ''
            addAutoPatchelfSearchPath ${final."apache-tvm-ffi"}/lib/python3.12/site-packages/tvm_ffi/lib
          '';
        });
        "nvidia-cufile" = prev."nvidia-cufile".overrideAttrs (old: {
          buildInputs = (old.buildInputs or [ ]) ++ [ pkgs.rdma-core ];
        });
        "nvidia-cusparse" = prev."nvidia-cusparse".overrideAttrs (old: {
          buildInputs = (old.buildInputs or [ ]) ++ [ final."nvidia-nvjitlink" ];
          preFixup = (old.preFixup or "") + ''
            addAutoPatchelfSearchPath ${final."nvidia-nvjitlink"}/lib/python3.12/site-packages/nvidia/cu13/lib
          '';
        });
        "nvidia-cusolver" = prev."nvidia-cusolver".overrideAttrs (old: {
          buildInputs = (old.buildInputs or [ ]) ++ [
            final."nvidia-cublas"
            final."nvidia-cusparse"
            final."nvidia-nvjitlink"
          ];
          preFixup = (old.preFixup or "") + ''
            addAutoPatchelfSearchPath ${final."nvidia-cublas"}/lib/python3.12/site-packages/nvidia/cu13/lib
            addAutoPatchelfSearchPath ${final."nvidia-cusparse"}/lib/python3.12/site-packages/nvidia/cu13/lib
            addAutoPatchelfSearchPath ${final."nvidia-nvjitlink"}/lib/python3.12/site-packages/nvidia/cu13/lib
          '';
        });
        "nvidia-nvshmem-cu13" = prev."nvidia-nvshmem-cu13".overrideAttrs (old: {
          buildInputs = (old.buildInputs or [ ]) ++ [
            pkgs.libfabric
            pkgs.openmpi
            pkgs.rdma-core
            pkgs.ucx
          ];
        });
      })
    ]
  );
  environment = pythonSet.mkVirtualEnv "vllm-0.25.1" workspace.deps.default;
  cudaToolkit = pkgs.symlinkJoin {
    name = "vllm-cuda-toolkit-13.0";
    paths = with pkgs.cudaPackages_13_0; [
      cccl
      cuda_crt
      cuda_cudart
      cuda_nvcc
      libcurand.include
      libcurand.lib
    ];
    postBuild = ''
      ln -s lib "$out/lib64"
    '';
  };
in
environment.overrideAttrs (old: {
  pname = "vllm";
  version = "0.25.1";
  nativeBuildInputs = (old.nativeBuildInputs or [ ]) ++ [ pkgs.makeWrapper ];
  # Two upstream wheels accidentally install their build helper at the
  # environment root. It is not imported by either runtime package.
  venvIgnoreCollisions = (old.venvIgnoreCollisions or [ ]) ++ [
    "lib/python3.12/site-packages/build_backend.py"
    # NVIDIA publishes base and CUDA-13 CUTLASS wheels as an overlaying
    # namespace; their shared files intentionally collide.
    "lib/python3.12/site-packages/nvidia_cutlass_dsl/*"
  ];
  postFixup = (old.postFixup or "") + ''
    for program in python python3 vllm; do
      if [ -e "$out/bin/$program" ]; then
        wrapProgram "$out/bin/$program" \
          --set-default CC ${pkgs.stdenv.cc}/bin/cc \
          --set-default CXX ${pkgs.stdenv.cc}/bin/c++ \
          --set-default CUDA_HOME ${cudaToolkit} \
          --set-default TRITON_LIBCUDA_PATH /run/opengl-driver/lib \
          --prefix PATH : ${
            lib.makeBinPath [
              cudaToolkit
              pkgs.ninja
            ]
          } \
          --prefix LIBRARY_PATH : "${cudaToolkit}/lib:/run/opengl-driver/lib" \
          --prefix LD_LIBRARY_PATH : "${
            lib.makeLibraryPath [ pkgs.stdenv.cc.cc.lib ]
          }:/run/opengl-driver/lib"
      fi
    done
  '';
  meta = (old.meta or { }) // {
    description = "Pinned vLLM inference environment for NemoClaw";
    homepage = "https://github.com/vllm-project/vllm";
    license = lib.licenses.asl20;
    mainProgram = "vllm";
    platforms = supportedSystems;
  };
  passthru = (old.passthru or { }) // {
    pythonPackageSet = pythonSet;
  };
})
