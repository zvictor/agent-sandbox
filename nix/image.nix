{ pkgs, unstable, devPackages }:
let
  devPackagesFinal =
    if builtins.isList devPackages then
      devPackages
    else if builtins.isAttrs devPackages && devPackages ? devPackages then
      devPackages.devPackages
    else
      builtins.throw ''
        agent-sandbox: devPackages must be a list (or an attrset containing devPackages)
      '';

  helpers = with pkgs.dockerTools; [
    usrBinEnv
    binSh
    caCertificates
    fakeNss
  ];

  gitWrapper = pkgs.writeShellScriptBin "git" ''
    #!/bin/sh
    set -e

    if [ -n "''${GIT_ALLOW:-}" ]; then
      exec ${pkgs.git}/bin/git "$@"
    fi

    SAFE_COMMANDS="clone|fetch|status|diff|log|show|branch|ls-files|rev-parse|describe|ls-tree|cat-file|blame|grep|reflog|config|remote|tag|for-each-ref|rev-list|shortlog|symbolic-ref|name-rev|merge-base"
    SUBCOMMAND=""

    while [ "$#" -gt 0 ]; do
      arg="$1"
      case "$arg" in
        -C|--git-dir|--work-tree|-c)
          shift 2 ;;
        --*) shift ;;
        -*) shift ;;
        *) SUBCOMMAND="$arg"; break ;;
      esac
    done

    if [ -z "$SUBCOMMAND" ]; then
      exec ${pkgs.git}/bin/git "$@"
    fi

    if echo "$SUBCOMMAND" | grep -qE "^($SAFE_COMMANDS)"; then
      exec ${pkgs.git}/bin/git "$@"
    fi

    echo "Error: git $SUBCOMMAND is blocked (side effects not allowed)" >&2
    exit 1
  '';

  tools = {
    codex = {
      pkg = "@openai/codex";
      bin = "codex";
      latest = true;
    };
    opencode = {
      pkg = "opencode-ai";
      bin = "opencode";
      latest = true;
    };
    claude = {
      pkg = "@anthropic-ai/claude-code";
      bin = "claude";
      latest = true;
    };
    codemachine = {
      pkg = "codemachine";
      bin = "codemachine";
      latest = true;
    };
  };

  mkBunToolLauncher =
    {
      name,
      pkg,
      bin ? name,
      latest ? false,
    }:
    let
      latestFlag = if latest then "1" else "0";
    in
    pkgs.writeShellScriptBin name ''
      #!/bin/sh
      set -euo pipefail

      CACHE_DIR="''${TOOL_CACHE:-/cache}/${name}"
      mkdir -p "$CACHE_DIR"

      if [ "${name}" = "codex" ]; then
        export CODEX_HOME="''${CODEX_HOME:-/config/.codex}"
        export CODEX_CONFIG_DIR="''${CODEX_CONFIG_DIR:-''${CODEX_HOME}}"
      fi

      if [ ! -f "$CACHE_DIR/package.json" ]; then
        (cd "$CACHE_DIR" && bun init -y >/dev/null)
      fi

      pkg_json="$CACHE_DIR/node_modules/${pkg}/package.json"
      bin_path="$CACHE_DIR/node_modules/.bin/${bin}"

      if [ "${latestFlag}" = "1" ]; then
        current_version=""
        if [ -f "$pkg_json" ]; then
          current_version=$(bun --print "require('$pkg_json').version" 2>/dev/null || true)
          echo "${pkg} is cached as version ''${current_version:-unknown}" >&2
        fi

        latest_version="$(bun info ${pkg} version 2>/dev/null | head -n1 || true)"
        if [ -z "$latest_version" ]; then
          if [ -z "$current_version" ]; then
            echo "Could not resolve latest ${pkg}; installing unpinned package..." >&2
            (cd "$CACHE_DIR" && bun add "${pkg}")
          fi
        elif [ "$current_version" != "$latest_version" ]; then
          echo "Installing ${pkg}@$latest_version..." >&2
          (cd "$CACHE_DIR" && bun add "${pkg}@$latest_version")
        fi
      else
        if [ ! -f "$pkg_json" ]; then
          echo "Installing ${pkg}..." >&2
          (cd "$CACHE_DIR" && bun add "${pkg}")
        fi
      fi

      if [ ! -x "$bin_path" ]; then
        echo "Expected launcher missing after install: $bin_path" >&2
        exit 1
      fi

      bun "$bin_path" "$@"
    '';

  toolsWithName = builtins.mapAttrs (name: tool: tool // { inherit name; }) tools;
  toolLaunchers = builtins.attrValues (builtins.mapAttrs (_: tool: mkBunToolLauncher tool) toolsWithName);

  direnvEtc = pkgs.runCommand "direnv-etc" { } ''
    mkdir -p "$out/etc/direnv"
    ln -s ${pkgs.nix-direnv}/share/nix-direnv/direnvrc "$out/etc/direnv/direnvrc"
  '';

  imageRoot = pkgs.buildEnv {
    name = "agent-rootfs";
    paths =
      [
        gitWrapper
        pkgs.nix
        pkgs.direnv
        pkgs.nix-direnv
        direnvEtc
        unstable.podman-compose
        pkgs.bashInteractive
        pkgs.busybox
        pkgs.docker
        pkgs.docker-compose
        pkgs.perl
        pkgs.python3
        pkgs.uv
        pkgs.curl
        pkgs.wget
        pkgs.jq
        pkgs.fx
        pkgs.bun
      ]
      ++ helpers
      ++ devPackagesFinal
      ++ toolLaunchers;

    pathsToLink = [
      "/bin"
      "/usr/bin"
      "/lib"
      "/libexec"
      "/share"
      "/etc"
    ];

    ignoreCollisions = true;
  };

  imageSpec = {
    name = "agent-base";
    tag = "latest";
    maxLayers = 64;
    contents = [ imageRoot ];
    includeNixDB = true;

    fakeRootCommands = ''
      mkdir -p lib64
      ln -sf ${pkgs.glibc.out}/lib/ld-linux-x86-64.so.2 lib64/ld-linux-x86-64.so.2

      mkdir -p nix/store nix/var/nix nix/var/log/nix nix/var/db
      rm -rf nix/var/nix/profiles nix/var/nix/gcroots
      ln -s /cache/nix/profiles nix/var/nix/profiles
      ln -s /cache/nix/gcroots nix/var/nix/gcroots
      chmod -R 0777 nix

      mkdir -p nixcache && chmod 0777 nixcache
      mkdir -p tmp && chmod 1777 tmp
      mkdir -p config && chmod 0777 config
      mkdir -p workspace
    '';

    config = {
      WorkingDir = "/workspace";
      Entrypoint = [ "/bin/codex" ];
      Env = [
        "PATH=/bin:/usr/bin:/usr/local/bin:/workspace/node_modules/.bin:${pkgs.lib.makeBinPath devPackagesFinal}:${pkgs.docker}/bin:${pkgs.bashInteractive}/bin"
        "HOME=/cache"
        "XDG_CACHE_HOME=/cache"
        "TOOL_CACHE=/cache"
        "CODEX_CACHE=/cache"
        "TESTCONTAINERS_RYUK_DISABLED=true"
        "NIX_PATH=nixpkgs=${pkgs.path}"
        "NIX_CONFIG=sandbox = false\nsubstituters = https://cache.nixos.org\ntrusted-public-keys = cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY"
      ];
    };
  };
in
{
  inherit tools;

  archiveImage = pkgs.dockerTools.buildImage {
    name = imageSpec.name;
    tag = imageSpec.tag;
    copyToRoot = imageRoot;
    includeNixDB = true;
    extraCommands = ''
      mkdir -p lib64
      ln -sf ${pkgs.glibc.out}/lib/ld-linux-x86-64.so.2 lib64/ld-linux-x86-64.so.2

      mkdir -p nix/store nix/var/nix nix/var/log/nix nix/var/db
      rm -rf nix/var/nix/profiles nix/var/nix/gcroots
      ln -s /cache/nix/profiles nix/var/nix/profiles
      ln -s /cache/nix/gcroots nix/var/nix/gcroots
      chmod -R 0777 nix

      mkdir -p nixcache && chmod 0777 nixcache
      mkdir -p tmp && chmod 1777 tmp
      mkdir -p config && chmod 0777 config
      mkdir -p workspace
    '';
    config = imageSpec.config;
  };

  layeredImage = pkgs.dockerTools.buildLayeredImage imageSpec;
  streamImage = pkgs.dockerTools.streamLayeredImage imageSpec;
}
