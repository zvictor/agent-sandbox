{
  description = "Reusable sandboxed agent wrappers (codex/claude/opencode)";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.11";
  };

  outputs = { self, nixpkgs }:
    let
      systems = [
        "x86_64-linux"
        "aarch64-linux"
      ];
      forAllSystems = nixpkgs.lib.genAttrs systems;
    in {
      packages = forAllSystems (system:
        let
          pkgs = import nixpkgs { inherit system; };

          sandboxRoot = pkgs.stdenvNoCC.mkDerivation {
            pname = "agent-sandbox-root";
            version = "0.1.0";
            src = self;
            dontBuild = true;
            installPhase = ''
              runHook preInstall
              mkdir -p "$out"
              cp -r default.nix nix scripts README.md "$out/"
              chmod +x "$out/scripts/agent" "$out/scripts/codex" "$out/scripts/claude" "$out/scripts/opencode"
              runHook postInstall
            '';
          };

          mkTool = toolName: pkgs.writeShellApplication {
            name = toolName;
            runtimeInputs = [
              pkgs.nix
              pkgs.coreutils
              pkgs.gawk
              pkgs.gnused
              pkgs.findutils
            ];
            text = ''
              exec "${sandboxRoot}/scripts/${toolName}" "$@"
            '';
          };
        in {
          agent = mkTool "agent";
          codex = mkTool "codex";
          claude = mkTool "claude";
          opencode = mkTool "opencode";
          default = mkTool "agent";
        });

      apps = forAllSystems (system:
        let
          p = self.packages.${system};
          mkApp = program: {
            type = "app";
            inherit program;
          };
        in {
          default = mkApp "${p.agent}/bin/agent";
          agent = mkApp "${p.agent}/bin/agent";
          codex = mkApp "${p.codex}/bin/codex";
          claude = mkApp "${p.claude}/bin/claude";
          opencode = mkApp "${p.opencode}/bin/opencode";
        });
    };
}
