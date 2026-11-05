{
  description = "Nix package and sandboxed NixOS module for Mesh-LLM/mesh-llm";

  inputs = {
    flake-schemas.url = "https://flakehub.com/f/DeterminateSystems/flake-schemas/*";
    nixpkgs.url = "https://flakehub.com/f/NixOS/nixpkgs/*";
  };

  outputs = { self, flake-schemas, nixpkgs }:
    let
      supportedSystems = [ "x86_64-linux" ];
      forEachSupportedSystem = f: nixpkgs.lib.genAttrs supportedSystems (system: f {
        pkgs = import nixpkgs { inherit system; };
      });
    in
    {
      schemas = flake-schemas.schemas;

      packages = forEachSupportedSystem ({ pkgs }: rec {
        mesh-llm = pkgs.callPackage ./package.nix { };
        default = mesh-llm;
      });

      apps = forEachSupportedSystem ({ pkgs }: rec {
        mesh-llm = {
          type = "app";
          program = "${self.packages.${pkgs.stdenv.hostPlatform.system}.mesh-llm}/bin/mesh-llm";
          meta.description = "Pool GPUs over the internet for LLM inference";
        };
        default = mesh-llm;
      });

      nixosModules = rec {
        mesh-llm = import ./module.nix self;
        default = mesh-llm;
      };

      checks = forEachSupportedSystem ({ pkgs }:
        let
          package = self.packages.${pkgs.stdenv.hostPlatform.system}.mesh-llm;
        in
        {
          mesh-llm = pkgs.runCommand "mesh-llm-smoke-test" { } ''
            export HOME="$TMPDIR"
            export DO_NOT_TRACK=1
            "${package}/bin/mesh-llm" --version | grep -Fx 'mesh-llm ${package.version}'
            "${package}/bin/mesh-llm" runtime list > "$TMPDIR/runtimes.txt" 2>&1
            grep -F 'meshllm-native-runtime-linux-x86_64-vulkan' "$TMPDIR/runtimes.txt"
            touch "$out"
          '';
        });

      formatter = forEachSupportedSystem ({ pkgs }: pkgs.nixpkgs-fmt);

      devShells = forEachSupportedSystem ({ pkgs }: {
        default = pkgs.mkShell {
          packages = with pkgs; [
            curl
            jj
            nixpkgs-fmt
          ];
        };
      });
    };
}
