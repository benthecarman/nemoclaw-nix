{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.services.nixclaw;
  vllm = config.services.nemoclawVllm;
  profile = vllm.profiles.${vllm.activeProfile};
  profileFields = [
    "gpuMemoryUtilization"
    "maxModelLen"
    "maxNumSeqs"
    "maxNumBatchedTokens"
    "tensorParallelSize"
    "pipelineParallelSize"
    "enablePrefixCaching"
    "enableChunkedPrefill"
    "enforceEager"
    "kvCacheDtype"
  ];
  nodeType = lib.types.submodule (
    { config, ... }: {
      options = {
        id = lib.mkOption { type = lib.types.strMatching "[A-Za-z0-9][A-Za-z0-9._-]{0,63}"; };
        role = lib.mkOption {
          type = lib.types.enum [
            "head"
            "worker"
          ];
          default = "worker";
        };
        rank = lib.mkOption { type = lib.types.ints.unsigned; };
        local = lib.mkOption {
          type = lib.types.bool;
          default = false;
        };
        sshTarget = lib.mkOption {
          type = lib.types.str;
          default = "";
        };
        healthy = lib.mkOption {
          type = lib.types.bool;
          default = true;
          readOnly = true;
        };
      };
    }
  );
  gpuType = lib.types.submodule {
    options = {
      model = lib.mkOption { type = lib.types.str; };
      count = lib.mkOption {
        type = lib.types.ints.positive;
        default = 1;
      };
      computeCapability = lib.mkOption { type = lib.types.str; };
      memoryBytes = lib.mkOption { type = lib.types.ints.unsigned; };
    };
  };
  tunableType = lib.types.enum profileFields;
  activeProfile = profile;
  clusterNodes = map (node: {
    inherit (node)
      id
      role
      rank
      healthy
      ;
  }) cfg.cluster.nodes;
  brokerConfig = pkgs.writeText "nixclaw-broker-v1.json" (
    builtins.toJSON {
      listenAddress = cfg.broker.listenAddress;
      port = cfg.broker.port;
      tokenFile = cfg.broker.tokenFile;
      maxRequestBytes = cfg.broker.maxRequestBytes;
      maxProposalBytes = cfg.broker.maxProposalBytes;
      editablePaths = cfg.broker.editablePaths;
      buildTimeoutSeconds = cfg.broker.buildTimeoutSeconds;
      source = toString cfg.source;
      configurationName = cfg.configurationName;
      stateDirectory = "/var/lib/nixclaw-broker";
      workDirectory = "/var/lib/nixclaw-broker/work";
      activeProfileName = vllm.activeProfile;
      inherit activeProfile;
      servedModel = if vllm.servedModelName != null then vllm.servedModelName else vllm.model;
      workloadIds = cfg.workloadIds;
      tunableFields = cfg.tunableFields;
      nixosRevision = cfg.nixosRevision;
      gpuFacts = cfg.facts.gpus;
      inherit clusterNodes;
      healthServices = cfg.health.services;
      healthUrls = cfg.health.urls;
    }
  );
  activatorConfig = pkgs.writeText "nixclaw-activator-v1.json" (
    builtins.toJSON {
      socketPath = "/run/nixclaw/activator.sock";
      socketGroup = cfg.activator.operatorGroup;
      stateDirectory = "/var/lib/nixclaw-activator";
      brokerStateDirectory = "/var/lib/nixclaw-broker";
      brokerGroup = "nixclaw-broker";
      leaseSeconds = cfg.activator.leaseSeconds;
      commandTimeoutSeconds = cfg.activator.commandTimeoutSeconds;
      healthTimeoutSeconds = cfg.health.timeoutSeconds;
      healthServices = cfg.health.services;
      healthUrls = cfg.health.urls;
      nodes = cfg.cluster.nodes;
    }
  );
in
{
  options.services.nixclaw = {
    enable = lib.mkEnableOption "the NixClaw controlled NixOS improvement platform";
    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.nixclaw-platform;
      defaultText = "pkgs.nixclaw-platform";
    };
    source = lib.mkOption {
      type = lib.types.path;
      description = "Clean flake source containing the target NixOS configuration.";
    };
    configurationName = lib.mkOption {
      type = lib.types.str;
      description = "nixosConfigurations attribute built for candidates.";
    };
    nixosRevision = lib.mkOption {
      type = lib.types.str;
      default = config.system.nixos.revision or "unknown";
    };
    workloadIds = lib.mkOption {
      type = lib.types.listOf (lib.types.strMatching "[A-Za-z0-9][A-Za-z0-9._-]{0,63}");
      default = [
        "interactive"
        "agent-tools"
      ];
    };
    tunableFields = lib.mkOption {
      type = lib.types.listOf tunableType;
      default = profileFields;
    };
    broker = {
      listenAddress = lib.mkOption {
        type = lib.types.str;
        default = "127.0.0.1";
      };
      port = lib.mkOption {
        type = lib.types.port;
        default = 8787;
      };
      tokenFile = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Root-provisioned bearer-token file readable by the broker.";
      };
      maxRequestBytes = lib.mkOption {
        type = lib.types.ints.positive;
        default = 65536;
      };
      maxProposalBytes = lib.mkOption {
        type = lib.types.ints.positive;
        default = 65536;
      };
      editablePaths = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ "nixclaw/agent-managed.nix" ];
      };
      buildTimeoutSeconds = lib.mkOption {
        type = lib.types.ints.positive;
        default = 3600;
      };
    };
    activator = {
      operatorGroup = lib.mkOption {
        type = lib.types.str;
        default = "nixclaw-operators";
      };
      leaseSeconds = lib.mkOption {
        type = lib.types.ints.positive;
        default = 300;
      };
      commandTimeoutSeconds = lib.mkOption {
        type = lib.types.ints.positive;
        default = 600;
      };
    };
    cluster.nodes = lib.mkOption {
      type = lib.types.listOf nodeType;
      default = [
        {
          id = config.networking.hostName;
          role = "head";
          rank = 0;
          local = true;
        }
      ];
    };
    health = {
      services = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ "nemoclaw-vllm.service" ];
      };
      urls = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ "http://127.0.0.1:8000/health" ];
      };
      timeoutSeconds = lib.mkOption {
        type = lib.types.ints.positive;
        default = 120;
      };
    };
    facts.gpus = lib.mkOption {
      type = lib.types.listOf gpuType;
      default = [ ];
      description = "Sanitized declarative GPU facts exposed to the optimizer.";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = vllm.enable;
        message = "services.nixclaw requires services.nemoclawVllm.enable.";
      }
      {
        assertion = cfg.facts.gpus != [ ];
        message = "services.nixclaw.facts.gpus must describe the canary GPU.";
      }
      {
        assertion = cfg.cluster.nodes != [ ];
        message = "services.nixclaw.cluster.nodes must not be empty.";
      }
      {
        assertion =
          lib.length (lib.unique (map (node: node.id) cfg.cluster.nodes)) == lib.length cfg.cluster.nodes;
        message = "NixClaw cluster node IDs must be unique.";
      }
      {
        assertion =
          lib.length (lib.unique (map (node: node.rank) cfg.cluster.nodes)) == lib.length cfg.cluster.nodes;
        message = "NixClaw cluster ranks must be unique.";
      }
      {
        assertion = lib.count (node: node.role == "head") cfg.cluster.nodes == 1;
        message = "NixClaw cluster requires exactly one head node.";
      }
      {
        assertion = lib.all (node: node.local || node.sshTarget != "") cfg.cluster.nodes;
        message = "Remote NixClaw nodes require sshTarget.";
      }
      {
        assertion = cfg.broker.listenAddress == "127.0.0.1" || cfg.broker.tokenFile != null;
        message = "A non-loopback broker requires a bearer token file.";
      }
    ];

    environment.systemPackages = [ cfg.package ];
    users.groups.${cfg.activator.operatorGroup} = { };
    users.groups.nixclaw-broker = { };
    users.users.nixclaw-broker = {
      isSystemUser = true;
      group = "nixclaw-broker";
      home = "/var/lib/nixclaw-broker";
    };
    nix.settings.allowed-users = [ "nixclaw-broker" ];

    systemd.services.nixclaw-broker = {
      description = "NixClaw unprivileged candidate broker";
      wantedBy = [ "multi-user.target" ];
      after = [ "network-online.target" ];
      serviceConfig = {
        User = "nixclaw-broker";
        Group = "nixclaw-broker";
        ExecStart = "${cfg.package}/bin/nixclaw-broker --config ${brokerConfig}";
        StateDirectory = "nixclaw-broker";
        Restart = "on-failure";
        RestartSec = 5;
        NoNewPrivileges = true;
        PrivateTmp = true;
        ProtectHome = true;
        ProtectSystem = "strict";
        ReadWritePaths = [ "/var/lib/nixclaw-broker" ];
      };
    };
    systemd.services.nixclaw-activator = {
      description = "NixClaw root-only generation activator";
      wantedBy = [ "multi-user.target" ];
      after = [ "nixclaw-broker.service" ];
      serviceConfig = {
        User = "root";
        Group = cfg.activator.operatorGroup;
        ExecStart = "${cfg.package}/bin/nixclaw-activator --config ${activatorConfig}";
        StateDirectory = "nixclaw-activator";
        RuntimeDirectory = "nixclaw";
        RuntimeDirectoryMode = "0750";
        Restart = "on-failure";
        RestartSec = 5;
        UMask = "0007";
        PrivateTmp = true;
        ProtectHome = false;
      };
    };
  };
}
