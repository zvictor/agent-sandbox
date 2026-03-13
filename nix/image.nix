{ pkgs, devPackages, nix2containerPkgs }:
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

  devPackagesImage = builtins.filter (
    pkg:
    !(
      (pkg ? pname && pkg.pname == "git")
      || (pkg ? name && pkgs.lib.hasPrefix "git-" pkg.name)
      || (pkg ? pname && pkg.pname == "bun")
      || (pkg ? name && pkgs.lib.hasPrefix "bun-" pkg.name)
    )
  ) devPackagesFinal;

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
    omp = {
      pkg = "@oh-my-pi/pi-coding-agent";
      bin = "omp";
      latest = true;
    };
  };

  agentNixTool = pkgs.runCommand "agent-nix-tool" { } ''
    install -Dm0755 ${../scripts/image/agent-nix-tool.sh} "$out/bin/agent-nix-tool"
  '';

  agentCompatScript = pkgs.substituteAll {
    src = ../scripts/image/agent-compat.sh;
    nixReal = "${pkgs.nix}/bin/nix";
    nixShellReal = "${pkgs.nix}/bin/nix-shell";
  };

  agentCompat = pkgs.runCommand "agent-compat" { } ''
    install -Dm0755 ${agentCompatScript} "$out/bin/agent-compat"
  '';

  mkCompatWrapper =
    name: subcommand:
    pkgs.writeShellScriptBin name ''
      #!/usr/bin/env bash
      set -euo pipefail
      exec /bin/agent-compat ${subcommand} "$@"
    '';

  agentShellEnv = pkgs.writeTextDir "etc/agent-shell-env.sh" (builtins.readFile ../scripts/image/agent-shell-env.sh);

  compatWrappers = [
    (mkCompatWrapper "nix" "nix-wrapper")
    (mkCompatWrapper "nix-shell" "nix-shell-wrapper")
    (mkCompatWrapper "podman" "run-command podman")
    (mkCompatWrapper "docker" "run-command docker")
  ];

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
        (cd "$CACHE_DIR" && ${pkgs.bun}/bin/bun init -y >/dev/null)
      fi

      pkg_json="$CACHE_DIR/node_modules/${pkg}/package.json"
      bin_path="$CACHE_DIR/node_modules/.bin/${bin}"

      if [ "${latestFlag}" = "1" ]; then
        current_version=""
        if [ -f "$pkg_json" ]; then
          current_version=$(${pkgs.bun}/bin/bun --print "require('$pkg_json').version" 2>/dev/null || true)
          echo "${pkg} is cached as version ''${current_version:-unknown}" >&2
        fi

        latest_version="$(${pkgs.bun}/bin/bun info ${pkg} version 2>/dev/null | head -n1 || true)"
        if [ -z "$latest_version" ]; then
          if [ -z "$current_version" ]; then
            echo "Could not resolve latest ${pkg}; installing unpinned package..." >&2
            (cd "$CACHE_DIR" && ${pkgs.bun}/bin/bun add "${pkg}")
          fi
        elif [ "$current_version" != "$latest_version" ]; then
          echo "Installing ${pkg}@$latest_version..." >&2
          (cd "$CACHE_DIR" && ${pkgs.bun}/bin/bun add "${pkg}@$latest_version")
        fi
      else
        if [ ! -f "$pkg_json" ]; then
          echo "Installing ${pkg}..." >&2
          (cd "$CACHE_DIR" && ${pkgs.bun}/bin/bun add "${pkg}")
        fi
      fi

      if [ ! -x "$bin_path" ]; then
        echo "Expected launcher missing after install: $bin_path" >&2
        exit 1
      fi

      ${pkgs.bun}/bin/bun "$bin_path" "$@"
    '';

  toolsWithName = builtins.mapAttrs (name: tool: tool // { inherit name; }) tools;
  toolLaunchers = builtins.attrValues (builtins.mapAttrs (_: tool: mkBunToolLauncher tool) toolsWithName);

  direnvEtc = pkgs.runCommand "direnv-etc" { } ''
    mkdir -p "$out/etc/direnv"
    ln -s ${pkgs.nix-direnv}/share/nix-direnv/direnvrc "$out/etc/direnv/direnvrc"
  '';

  n2c = nix2containerPkgs.nix2container;

  skeleton = pkgs.runCommand "image-skeleton" { } ''
    mkdir -p "$out/lib64"
    ln -sf ${pkgs.glibc.out}/lib/ld-linux-x86-64.so.2 "$out/lib64/ld-linux-x86-64.so.2"

    mkdir -p "$out/nix/store" "$out/nix/var/nix" "$out/nix/var/log/nix" "$out/nix/var/db"
    ln -s /cache/nix/profiles "$out/nix/var/nix/profiles"
    ln -s /cache/nix/gcroots "$out/nix/var/nix/gcroots"

    mkdir -p "$out/nixcache" "$out/tmp" "$out/config" "$out/workspace"
    mkdir -p "$out/run" "$out/run/agent-container-api" "$out/run/agent-nix-helper" "$out/run/secrets" "$out/var/run"
  '';

  imageBasePaths =
    [
      skeleton
      gitWrapper
      agentCompat
      pkgs.direnv
      pkgs.nix
      pkgs.nix-direnv
      direnvEtc
      agentShellEnv
      pkgs.bashInteractive
      pkgs.coreutils
      pkgs.gnugrep
      pkgs.gnused
      pkgs.gawk
      pkgs.findutils
      pkgs.curl
      pkgs.wget
      pkgs.jq
      pkgs.fx
      pkgs.bun
    ]
    ++ helpers
    ++ devPackagesImage
    ++ toolLaunchers
    ++ compatWrappers
    ++ [ agentNixTool ];

  imageSpec = {
    name = "agent-base";
    tag = "latest";
    maxLayers = 120;

    copyToRoot = imageBasePaths;

    config = {
      WorkingDir = "/workspace";
      Entrypoint = [ "/bin/codex" ];
      Env = [
        "PATH=/bin:/usr/bin:/usr/local/bin:/workspace/node_modules/.bin:${pkgs.lib.makeBinPath devPackagesFinal}:${pkgs.bashInteractive}/bin"
        "HOME=/cache"
        "XDG_CACHE_HOME=/cache"
        "TOOL_CACHE=/cache"
        "CODEX_CACHE=/cache"
        "TESTCONTAINERS_RYUK_DISABLED=true"
        "BASH_ENV=/etc/agent-shell-env.sh"
        "ENV=/etc/agent-shell-env.sh"
        "SHELL=/bin/bash"
        "NIX_PATH=nixpkgs=${pkgs.path}"
        "NIX_CONFIG=sandbox = false\nsubstituters = https://cache.nixos.org\ntrusted-public-keys = cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY"
      ];
    };
  };
in
rec {
  inherit tools;

  rootfs = pkgs.buildEnv {
    name = "agent-rootfs";
    pathsToLink = [ "/" ];
    paths = imageBasePaths;
    postBuild = ''
      # Podman --rootfs reads /etc/passwd via SecureJoin before mounts are
      # applied; keep NSS files as real files (not /nix/store symlinks).
      rm -f "$out/etc/passwd" "$out/etc/group" "$out/etc/nsswitch.conf"
      install -Dm0644 -T "${pkgs.dockerTools.fakeNss}/etc/passwd" "$out/etc/passwd"
      install -Dm0644 -T "${pkgs.dockerTools.fakeNss}/etc/group" "$out/etc/group"
      install -Dm0644 -T "${pkgs.dockerTools.fakeNss}/etc/nsswitch.conf" "$out/etc/nsswitch.conf"

      # In rootfs mode Podman mounts volumes before command execution and
      # expects destination paths to be normal directories, not symlink chains.
      for d in \
        cache config workspace nixcache tmp run run/agent-container-api run/agent-nix-helper run/secrets var/run \
        nix nix/store nix/var/nix nix/var/log/nix nix/var/db
      do
        rm -rf "$out/$d"
        mkdir -p "$out/$d"
      done
      chmod 1777 "$out/tmp"
      ln -sfn /cache/nix/profiles "$out/nix/var/nix/profiles"
      ln -sfn /cache/nix/gcroots "$out/nix/var/nix/gcroots"
    '';
  };

  streamImage = n2c.buildImage imageSpec;
}
