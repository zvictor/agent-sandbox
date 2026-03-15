{ pkgs, devPackages, nix2containerPkgs }:
let
  isShadowedImagePackage =
    pkg:
    let
      pname = if pkg ? pname then pkg.pname else "";
      name = if pkg ? name then pkg.name else "";
    in
    pname == "git"
    || pkgs.lib.hasPrefix "git-" name
    || pname == "bun"
    || pkgs.lib.hasPrefix "bun-" name
    || pname == "nix"
    || builtins.match "^nix-[0-9].*" name != null
    || pname == "podman"
    || builtins.match "^podman-[0-9].*" name != null
    || pname == "docker"
    || pname == "docker-client"
    || builtins.match "^docker(-client)?-[0-9].*" name != null;

  devPackagesFinal =
    if builtins.isList devPackages then
      devPackages
    else if builtins.isAttrs devPackages && devPackages ? devPackages then
      devPackages.devPackages
    else
      builtins.throw ''
        agent-sandbox: devPackages must be a list (or an attrset containing devPackages)
      '';

  devPackagesImage = builtins.filter (pkg: !(isShadowedImagePackage pkg)) devPackagesFinal;

  helpers = with pkgs.dockerTools; [
    usrBinEnv
    caCertificates
    fakeNss
  ];

  bashBin = pkgs.runCommand "bash-bin" { } ''
    mkdir -p "$out/bin"
    ln -s ${pkgs.bashInteractive}/bin/bash "$out/bin/bash"
  '';

  gitWrapper = pkgs.writeShellScriptBin "git" ''
    #!/bin/sh
    set -e

    if [ -n "''${GIT_ALLOW:-}" ]; then
      exec ${pkgs.git}/bin/git "$@"
    fi

    # Preserve the current repo's local state by default. `clone` is the only
    # write-capable exception because it creates a separate checkout rather than
    # mutating the current repository's index, refs, or config.
    SAFE_COMMANDS="clone|status|diff|log|show|ls-files|rev-parse|describe|ls-tree|cat-file|blame|grep|reflog|for-each-ref|rev-list|shortlog|symbolic-ref|name-rev|merge-base"
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

  needCommand = pkgs.runCommand "need" { } ''
    install -Dm0755 ${../scripts/image/need.sh} "$out/bin/need"
  '';

  agentCompatScript = pkgs.replaceVars ../scripts/image/agent-compat.sh {
    nixReal = "${pkgs.nix}/bin/nix";
    nixShellReal = "${pkgs.nix}/bin/nix-shell";
    shReal = "${pkgs.bashInteractive}/bin/sh";
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

  compatWrappers = [
    (mkCompatWrapper "sh" "sh-wrapper")
    (mkCompatWrapper "nix" "nix-wrapper")
    (mkCompatWrapper "nix-shell" "nix-shell-wrapper")
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
        export CODEX_HOME="''${CODEX_HOME:-/cache/.codex}"
        export CODEX_CONFIG_DIR="''${CODEX_CONFIG_DIR:-''${CODEX_HOME}}"
      fi

      if [ "''${AGENT_NEED_BOOTSTRAP_INDEX:-1}" = "1" ] && command -v need >/dev/null 2>&1; then
        /bin/need bootstrap-index >/dev/null 2>&1 || true
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

    mkdir -p "$out/nixcache" "$out/tmp" "$out/config"
    mkdir -p "$out/run" "$out/run/agent-container-api" "$out/run/agent-nix-helper" "$out/run/secrets" "$out/var/run"
  '';

  imageBasePaths =
    [
      skeleton
      gitWrapper
      agentCompat
      pkgs.direnv
      pkgs.nix-direnv
      direnvEtc
      bashBin
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
      pkgs.nix-index
    ]
    ++ helpers
    ++ devPackagesImage
    ++ toolLaunchers
    ++ compatWrappers
    ++ [ needCommand ];

  imageSpec = {
    name = "agent-base";
    tag = "latest";
    maxLayers = 120;

    copyToRoot = imageBasePaths;

    config = {
      WorkingDir = "/";
      Entrypoint = [ "/bin/codex" ];
      Env = [
        "PATH=/cache/need/bin:/bin:/usr/bin:/usr/local/bin:${pkgs.lib.makeBinPath devPackagesFinal}:${pkgs.bashInteractive}/bin"
        "HOME=/cache"
        "XDG_CACHE_HOME=/cache"
        "TOOL_CACHE=/cache"
        "CODEX_CACHE=/cache"
        "TESTCONTAINERS_RYUK_DISABLED=true"
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
        cache config nixcache tmp run run/agent-container-api run/agent-nix-helper run/secrets var/run \
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
