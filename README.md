# mesh-llm Nix flake

Packages [Mesh-LLM/mesh-llm](https://github.com/Mesh-LLM/mesh-llm) v0.78.1 for
`x86_64-linux` from the upstream Vulkan release bundle, and provides a sandboxed
NixOS module. Vulkan covers both NVIDIA and AMD GPUs, including Strix Halo.

Only the host binary's interpreter is patched; the native runtime libraries stay
byte-identical because mesh-llm verifies them against their manifest checksums.

## Usage

```sh
nix run . -- --help
nix run . -- client --auto      # use the public mesh without contributing
nix build .
```

## NixOS module

```nix
{
  imports = [ inputs.mesh-llm.nixosModules.default ];

  services.mesh-llm = {
    enable = true;
    # "client" (default) uses peers' models; "serve" also runs models here.
    mode = "client";
    extraArgs = [ "--auto" ];   # join the best public mesh
  };
}
```

The OpenAI-compatible API listens on `localhost:9337` and the console on
`localhost:3131`.

The service runs as a dedicated `mesh-llm` user with an empty capability set, a
read-only filesystem apart from `/var/lib/mesh-llm` and `/var/cache/mesh-llm`,
no access to `/home`, and GPU device nodes only in serve mode. With
`restrictLocalEgress` (the default) it also rejects new connections to loopback
and private networks,
apart from DNS and its own API ports, so a compromised node cannot reach other
services on the host or LAN. Add LANs that use public addresses to
`extraBlockedNetworks`.

Peers that serve your requests on a public mesh see prompts in plain text.

## Development

```sh
nix develop
nix fmt flake.nix package.nix module.nix
nix flake check
```

`nix flake check` runs `--version` and confirms the bundled Vulkan runtime is
discovered.
