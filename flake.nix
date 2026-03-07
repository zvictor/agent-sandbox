{
  description = "Reusable sandboxed agent runtime (codex/claude/opencode/codemachine/omp)";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.11";
    unstable.url = "github:NixOS/nixpkgs/nixos-unstable";
    nix2container = {
      url = "github:nlewo/nix2container";
    };

    # Always overridden by bin/agent using --override-input projectPkgs path:<store-path>
    projectPkgs = {
      url = "path:./nix/empty-project";
      flake = false;
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      unstable,
      nix2container,
      projectPkgs,
      ...
    }:
    let
      systems = [
        "x86_64-linux"
        "aarch64-linux"
      ];
      forAllSystems = nixpkgs.lib.genAttrs systems;
    in
    {
      packages = forAllSystems (
        system:
        let
          pkgs = import nixpkgs {
            inherit system;
            config.allowUnfree = true;
          };
          upkgs = import unstable {
            inherit system;
            config.allowUnfree = true;
          };

          devPackages = import ./nix/detect-packages.nix {
            inherit pkgs projectPkgs;
            unstable = upkgs;
          };

          images = import ./nix/image.nix {
            inherit pkgs devPackages;
            nix2containerPkgs = nix2container.packages.${system};
          };

          sandboxRoot = pkgs.stdenvNoCC.mkDerivation {
            pname = "agent-sandbox-root";
            version = "0.2.0";
            src = self;
            dontBuild = true;
            installPhase = ''
              runHook preInstall
              mkdir -p "$out"
              cp -r flake.nix flake.lock README.md bin nix scripts "$out/"
              chmod +x "$out/bin/agent" \
                "$out/scripts/agent" \
                "$out/scripts/codex" \
                "$out/scripts/claude" \
                "$out/scripts/opencode" \
                "$out/scripts/codemachine" \
                "$out/scripts/omp"
              runHook postInstall
            '';
          };

          runtimeInputs = [
            pkgs.bash
            pkgs.coreutils
            pkgs.findutils
            pkgs.gawk
            pkgs.gnused
            pkgs.jq
            pkgs.nix
            pkgs.git
            pkgs.docker
            pkgs.podman
          ];

          mkTool =
            toolName:
            pkgs.writeShellApplication {
              name = toolName;
              inherit runtimeInputs;
              text =
                if toolName == "agent" then
                  ''
                    exec "${sandboxRoot}/bin/agent" "$@"
                  ''
                else
                  ''
                    exec "${sandboxRoot}/bin/agent" ${toolName} "$@"
                  '';
            };
        in
        {
          streamImage = images.streamImage;
          rootfs = images.rootfs;

          agent-cli = mkTool "agent";
          agent = mkTool "agent";
          codex = mkTool "codex";
          claude = mkTool "claude";
          opencode = mkTool "opencode";
          codemachine = mkTool "codemachine";
          omp = mkTool "omp";
          default = mkTool "agent";
        }
      );

      apps = forAllSystems (
        system:
        let
          p = self.packages.${system};
          mkApp = program: {
            type = "app";
            inherit program;
          };
        in
        {
          default = mkApp "${p.agent}/bin/agent";
          agent = mkApp "${p.agent}/bin/agent";
          codex = mkApp "${p.codex}/bin/codex";
          claude = mkApp "${p.claude}/bin/claude";
          opencode = mkApp "${p.opencode}/bin/opencode";
          codemachine = mkApp "${p.codemachine}/bin/codemachine";
          omp = mkApp "${p.omp}/bin/omp";
        }
      );
    };
}
