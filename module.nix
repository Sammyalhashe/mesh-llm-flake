self:
{ config, lib, pkgs, ... }:

let
  cfg = config.services.mesh-llm;
  serving = cfg.mode == "serve";
  settingsFormat = pkgs.formats.toml { };

  configFile = pkgs.runCommand "mesh-llm-config.toml"
    {
      src = settingsFormat.generate "mesh-llm-config.toml" cfg.settings;
    } ''
    cp "$src" "$out"
    HOME="$TMPDIR" DO_NOT_TRACK=1 ${lib.getExe cfg.package} config validate --config-path "$out"
  '';

  privateNetworks = [
    "127.0.0.0/8"
    "10.0.0.0/8"
    "100.64.0.0/10"
    "169.254.0.0/16"
    "172.16.0.0/12"
    "192.168.0.0/16"
    "::1/128"
    "fc00::/7"
    "fe80::/10"
  ];
  blockedNetworks = privateNetworks ++ cfg.extraBlockedNetworks;
  isIPv6 = lib.hasInfix ":";
  chain = "mesh-llm-egress";

  egressRules = iptables: networks: ''
    ${iptables} -w -N ${chain} 2>/dev/null || ${iptables} -w -F ${chain}
    ${iptables} -w -C OUTPUT -m owner --uid-owner mesh-llm -j ${chain} 2>/dev/null \
      || ${iptables} -w -I OUTPUT -m owner --uid-owner mesh-llm -j ${chain}
    ${iptables} -w -A ${chain} -p udp --dport 53 -j RETURN
    ${iptables} -w -A ${chain} -p tcp --dport 53 -j RETURN
    ${iptables} -w -A ${chain} -o lo -p tcp -m multiport \
      --dports ${toString cfg.apiPort},${toString cfg.consolePort} -j RETURN
    ${lib.concatMapStrings (net: ''
      ${iptables} -w -A ${chain} -d ${net} -m conntrack --ctstate NEW -j REJECT
    '') networks}
  '';

  removeRules = iptables: ''
    ${iptables} -w -D OUTPUT -m owner --uid-owner mesh-llm -j ${chain} 2>/dev/null || true
    ${iptables} -w -F ${chain} 2>/dev/null || true
    ${iptables} -w -X ${chain} 2>/dev/null || true
  '';

  addEgressBlock = pkgs.writeShellScript "mesh-llm-egress-add" ''
    set -eu
    ${egressRules "${pkgs.iptables}/bin/iptables" (lib.filter (n: !isIPv6 n) blockedNetworks)}
    ${egressRules "${pkgs.iptables}/bin/ip6tables" (lib.filter isIPv6 blockedNetworks)}
  '';

  removeEgressBlock = pkgs.writeShellScript "mesh-llm-egress-remove" ''
    ${removeRules "${pkgs.iptables}/bin/iptables"}
    ${removeRules "${pkgs.iptables}/bin/ip6tables"}
  '';
in
{
  options.services.mesh-llm = {
    enable = lib.mkEnableOption "a sandboxed Mesh LLM node";

    package = lib.mkOption {
      type = lib.types.package;
      default = self.packages.${pkgs.stdenv.hostPlatform.system}.mesh-llm;
      defaultText = lib.literalExpression "mesh-llm-flake.packages.\${system}.mesh-llm";
      description = "The mesh-llm package to run.";
    };

    mode = lib.mkOption {
      type = lib.types.enum [ "client" "serve" ];
      default = "client";
      description = ''
        `client` uses models hosted by other peers without running any locally,
        and gets no GPU access. `serve` also runs models on this host for the mesh.
      '';
    };

    extraArgs = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ "--auto" ];
      example = [ "--model" "Qwen/Qwen2.5-3B-Instruct-GGUF@main:q4_k_m" "--publish" ];
      description = "Arguments passed to `mesh-llm <mode>`. The default joins the best public mesh.";
    };

    settings = lib.mkOption {
      inherit (settingsFormat) type;
      default = { };
      example = lib.literalExpression ''
        {
          request_defaults.chat_template_file = ./template.jinja;
          model_fit.ctx_size = 131072;
        }
      '';
      description = ''
        mesh-llm config.toml, validated at build time. See
        <https://meshllm.cloud/docs/pages/config-reference/>.
      '';
    };

    apiPort = lib.mkOption {
      type = lib.types.port;
      default = 9337;
      description = "Port of the OpenAI-compatible API.";
    };

    consolePort = lib.mkOption {
      type = lib.types.port;
      default = 3131;
      description = "Port of the management API and console.";
    };

    bindPort = lib.mkOption {
      type = lib.types.nullOr lib.types.port;
      default = null;
      description = "Fixed UDP port for mesh QUIC traffic in serve mode, so it can be opened for direct peer paths.";
    };

    openFirewall = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Whether to open `bindPort` (UDP) in the firewall.";
    };

    restrictLocalEgress = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Whether to reject new connections from the service to loopback and local
        networks, so a compromised node cannot reach other services on the host or LAN.
        DNS and the node's own API ports stay reachable.
      '';
    };

    extraBlockedNetworks = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [ "203.0.113.0/24" ];
      description = "Networks to block in addition to loopback and private ranges, such as a LAN that uses public addresses.";
    };

    analytics = lib.mkEnableOption "mesh-llm's anonymous usage reporting";

    memoryMax = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "24G";
      description = "systemd MemoryMax for the service.";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [{
      assertion = cfg.openFirewall -> cfg.bindPort != null;
      message = "services.mesh-llm.openFirewall requires services.mesh-llm.bindPort.";
    }];

    # Without a pin mesh-llm prefers a downloaded CUDA runtime whenever
    # nvidia-smi works, and that runtime cannot load outside an FHS system.
    services.mesh-llm.settings.runtime.native_runtime.selection = lib.mkDefault cfg.package.runtimeId;

    users.users.mesh-llm = {
      isSystemUser = true;
      group = "mesh-llm";
      extraGroups = lib.optionals serving [ "video" "render" ];
      home = "/var/lib/mesh-llm";
    };
    users.groups.mesh-llm = { };

    networking.firewall.allowedUDPPorts = lib.optional (cfg.openFirewall && cfg.bindPort != null) cfg.bindPort;

    systemd.services.mesh-llm = {
      description = "Mesh LLM node";
      wantedBy = [ "multi-user.target" ];
      wants = [ "network-online.target" ];
      after = [ "network-online.target" ];

      # mesh-llm reads NVIDIA VRAM from nvidia-smi.
      path = lib.optional (serving && lib.elem "nvidia" config.services.xserver.videoDrivers) config.hardware.nvidia.package.bin;

      environment = {
        HOME = "/var/lib/mesh-llm";
        XDG_CACHE_HOME = "/var/cache/mesh-llm";
        MESH_LLM_CONFIG = "${configFile}";
      } // lib.optionalAttrs (!cfg.analytics) {
        DO_NOT_TRACK = "1";
      };

      serviceConfig = {
        ExecStartPre = lib.optional cfg.restrictLocalEgress "+${addEgressBlock}";
        ExecStart = lib.escapeShellArgs ([
          (lib.getExe cfg.package)
          "--log-format"
          "json"
          cfg.mode
          "--port"
          (toString cfg.apiPort)
          "--console"
          (toString cfg.consolePort)
        ] ++ lib.optionals (serving && cfg.bindPort != null) [ "--bind-port" (toString cfg.bindPort) ]
        ++ cfg.extraArgs);
        ExecStopPost = lib.optional cfg.restrictLocalEgress "+${removeEgressBlock}";
        Restart = "on-failure";
        RestartSec = 10;

        User = "mesh-llm";
        Group = "mesh-llm";
        StateDirectory = "mesh-llm";
        CacheDirectory = "mesh-llm";
        WorkingDirectory = "/var/lib/mesh-llm";
        UMask = "0077";
        MemoryMax = lib.mkIf (cfg.memoryMax != null) cfg.memoryMax;

        DevicePolicy = "closed";
        DeviceAllow = lib.optionals serving [
          "char-drm rw"
          "char-kfd rw"
          "char-nvidia rw"
          "char-nvidiactl rw"
          "char-nvidia-modeset rw"
          "char-nvidia-uvm rw"
          "char-nvidia-caps rw"
        ];

        CapabilityBoundingSet = "";
        AmbientCapabilities = "";
        NoNewPrivileges = true;
        LockPersonality = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        PrivateTmp = true;
        ProtectClock = true;
        ProtectControlGroups = true;
        ProtectHostname = true;
        ProtectKernelLogs = true;
        ProtectKernelModules = true;
        ProtectKernelTunables = true;
        ProtectProc = "invisible";
        ProcSubset = "all";
        RemoveIPC = true;
        RestrictAddressFamilies = [ "AF_INET" "AF_INET6" "AF_UNIX" "AF_NETLINK" ];
        RestrictNamespaces = true;
        RestrictRealtime = true;
        RestrictSUIDSGID = true;
        SystemCallArchitectures = "native";
        SystemCallFilter = [ "@system-service" "~@privileged" ];
        SystemCallErrorNumber = "EPERM";
      };
    };
  };
}
