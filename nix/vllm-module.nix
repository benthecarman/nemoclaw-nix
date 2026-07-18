{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.services.nemoclawVllm;

  profileModule = lib.types.submodule {
    options = {
      gpuMemoryUtilization = lib.mkOption {
        type = lib.types.float;
        default = 0.76;
        description = "Fraction of GPU memory reserved by vLLM.";
      };

      maxModelLen = lib.mkOption {
        type = lib.types.ints.positive;
        default = 65536;
        description = "Maximum model context length.";
      };

      maxNumSeqs = lib.mkOption {
        type = lib.types.nullOr lib.types.ints.positive;
        default = null;
        description = "Optional maximum number of concurrent sequences.";
      };

      maxNumBatchedTokens = lib.mkOption {
        type = lib.types.nullOr lib.types.ints.positive;
        default = null;
        description = "Optional maximum number of tokens in one scheduler batch.";
      };

      tensorParallelSize = lib.mkOption {
        type = lib.types.ints.positive;
        default = 1;
        description = "Tensor-parallel worker count.";
      };

      pipelineParallelSize = lib.mkOption {
        type = lib.types.ints.positive;
        default = 1;
        description = "Pipeline-parallel worker count.";
      };

      enablePrefixCaching = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Enable vLLM automatic prefix caching.";
      };

      enableChunkedPrefill = lib.mkOption {
        type = lib.types.nullOr lib.types.bool;
        default = null;
        description = "Explicitly enable or disable chunked prefill, or use the vLLM default.";
      };

      enforceEager = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Disable CUDA graphs and force eager execution.";
      };

      kvCacheDtype = lib.mkOption {
        type = lib.types.nullOr (
          lib.types.enum [
            "auto"
            "fp8"
            "fp8_e4m3"
            "fp8_e5m2"
          ]
        );
        default = null;
        description = "Optional KV-cache data type.";
      };

      reasoningParser = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Optional model reasoning parser.";
      };

      toolCallParser = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Optional tool-call parser; also enables automatic tool choice.";
      };

      speculativeConfig = lib.mkOption {
        type = lib.types.nullOr (lib.types.attrsOf lib.types.anything);
        default = null;
        description = "Optional structured vLLM speculative decoding configuration.";
      };

      environment = lib.mkOption {
        type = lib.types.attrsOf lib.types.str;
        default = { };
        description = "Non-secret environment variables embedded in the immutable launcher.";
      };

      fixedArgs = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        description = "Administrator-reviewed additional vLLM arguments.";
      };
    };
  };

  profile = lib.attrByPath [ cfg.activeProfile ] (builtins.head (
    lib.attrValues cfg.profiles
  )) cfg.profiles;

  arguments = [
    "serve"
    cfg.model
    "--host"
    cfg.host
    "--port"
    (toString cfg.port)
    "--gpu-memory-utilization"
    (toString profile.gpuMemoryUtilization)
    "--max-model-len"
    (toString profile.maxModelLen)
    "--tensor-parallel-size"
    (toString profile.tensorParallelSize)
    "--pipeline-parallel-size"
    (toString profile.pipelineParallelSize)
  ]
  ++ lib.optionals (cfg.servedModelName != null) [
    "--served-model-name"
    cfg.servedModelName
  ]
  ++ lib.optionals (profile.maxNumSeqs != null) [
    "--max-num-seqs"
    (toString profile.maxNumSeqs)
  ]
  ++ lib.optionals (profile.maxNumBatchedTokens != null) [
    "--max-num-batched-tokens"
    (toString profile.maxNumBatchedTokens)
  ]
  ++ lib.optionals profile.enablePrefixCaching [ "--enable-prefix-caching" ]
  ++ lib.optionals (!profile.enablePrefixCaching) [ "--no-enable-prefix-caching" ]
  ++ lib.optionals (profile.enableChunkedPrefill == true) [ "--enable-chunked-prefill" ]
  ++ lib.optionals (profile.enableChunkedPrefill == false) [ "--no-enable-chunked-prefill" ]
  ++ lib.optionals profile.enforceEager [ "--enforce-eager" ]
  ++ lib.optionals (profile.kvCacheDtype != null) [
    "--kv-cache-dtype"
    profile.kvCacheDtype
  ]
  ++ lib.optionals (profile.reasoningParser != null) [
    "--reasoning-parser"
    profile.reasoningParser
  ]
  ++ lib.optionals (profile.toolCallParser != null) [
    "--enable-auto-tool-choice"
    "--tool-call-parser"
    profile.toolCallParser
  ]
  ++ lib.optionals (profile.speculativeConfig != null) [
    "--speculative-config"
    (builtins.toJSON profile.speculativeConfig)
  ]
  ++ profile.fixedArgs;

  environmentLines = lib.mapAttrsToList (
    name: value: "export ${name}=${lib.escapeShellArg value}"
  ) profile.environment;

  launcher = pkgs.writeShellApplication {
    name = "nemoclaw-vllm-serve";
    runtimeInputs = [ cfg.package ];
    text = ''
      ${lib.concatStringsSep "\n" environmentLines}
      exec vllm ${lib.escapeShellArgs arguments}
    '';
  };

  validEnvironmentName = name: builtins.match "[A-Za-z_][A-Za-z0-9_]*" name != null;
in
{
  options.services.nemoclawVllm = {
    enable = lib.mkEnableOption "a reproducible vLLM 0.25.1 inference service";

    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.vllm-nemoclaw;
      defaultText = lib.literalExpression "pkgs.vllm-nemoclaw";
      description = "The pinned vLLM package used by the immutable launcher.";
    };

    model = lib.mkOption {
      type = lib.types.str;
      example = "nvidia/NVIDIA-Nemotron-3-Super-120B-A12B-NVFP4";
      description = "Hugging Face model identifier or local model path.";
    };

    servedModelName = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Optional public model name returned by the OpenAI-compatible API.";
    };

    host = lib.mkOption {
      type = lib.types.str;
      default = "0.0.0.0";
      description = "Listen address. The module never opens the host firewall automatically.";
    };

    port = lib.mkOption {
      type = lib.types.port;
      default = 8000;
      description = "OpenAI-compatible API port.";
    };

    autoStart = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Start the selected serving profile at boot.";
    };

    activeProfile = lib.mkOption {
      type = lib.types.str;
      default = "baseline";
      description = "Profile rendered into the current immutable launcher.";
    };

    profiles = lib.mkOption {
      type = lib.types.attrsOf profileModule;
      default = {
        baseline = { };
      };
      description = "Named, declarative vLLM serving profiles.";
    };

    environmentFiles = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "Root-managed systemd environment files for runtime secrets.";
    };

    launcherPackage = lib.mkOption {
      type = lib.types.package;
      readOnly = true;
      description = "Generated immutable launcher for the selected profile.";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = builtins.hasAttr cfg.activeProfile cfg.profiles;
        message = "services.nemoclawVllm.activeProfile must name a declared profile.";
      }
      {
        assertion = lib.getVersion cfg.package == "0.25.1";
        message = "services.nemoclawVllm.package must provide vLLM 0.25.1.";
      }
      {
        assertion = profile.gpuMemoryUtilization > 0.0 && profile.gpuMemoryUtilization <= 1.0;
        message = "vLLM gpuMemoryUtilization must be greater than zero and at most one.";
      }
      {
        assertion = lib.all validEnvironmentName (lib.attrNames profile.environment);
        message = "vLLM profile environment keys must be valid environment variable names.";
      }
    ];

    services.nemoclawVllm.launcherPackage = launcher;

    users.groups.nemoclaw-vllm = { };
    users.users.nemoclaw-vllm = {
      isSystemUser = true;
      group = "nemoclaw-vllm";
      extraGroups = [
        "render"
        "video"
      ];
      home = "/var/lib/nemoclaw-vllm";
    };

    systemd.services.nemoclaw-vllm = {
      description = "NemoClaw local vLLM inference server (${cfg.activeProfile})";
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      wantedBy = lib.optionals cfg.autoStart [ "multi-user.target" ];

      serviceConfig = {
        User = "nemoclaw-vllm";
        Group = "nemoclaw-vllm";
        ExecStart = "${launcher}/bin/nemoclaw-vllm-serve";
        EnvironmentFile = cfg.environmentFiles;
        StateDirectory = "nemoclaw-vllm";
        CacheDirectory = "nemoclaw-vllm";
        WorkingDirectory = "/var/lib/nemoclaw-vllm";
        Restart = "on-failure";
        RestartSec = 10;
        LimitNOFILE = 1048576;
        NoNewPrivileges = true;
        PrivateTmp = true;
        ProtectHome = true;
        ProtectSystem = "strict";
        ReadWritePaths = [
          "/var/lib/nemoclaw-vllm"
          "/var/cache/nemoclaw-vllm"
        ];
      };

      environment = {
        HOME = "/var/lib/nemoclaw-vllm";
        HF_HOME = "/var/cache/nemoclaw-vllm/huggingface";
        VLLM_CACHE_ROOT = "/var/cache/nemoclaw-vllm/vllm";
      };
    };
  };
}
