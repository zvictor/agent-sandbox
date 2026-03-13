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

  agentNixTool = pkgs.writeShellScriptBin "agent-nix-tool" ''
    #!/bin/sh
    set -eu

    usage() {
      echo "usage: agent-nix-tool <add|env|run> <installable> [-- command args...]" >&2
      exit 1
    }

    BRIDGE_DIR="''${AGENT_NIX_TOOL_HELPER_DIR:-/run/agent-nix-helper}"
    REQUESTS_DIR="$BRIDGE_DIR/requests"
    RESPONSES_DIR="$BRIDGE_DIR/responses"
    TIMEOUT="''${AGENT_NIX_TOOL_TIMEOUT:-600}"

    helper_request() {
      installable="$1"
      req_id="$(date +%s)-$$-$(od -An -N4 -tx1 /dev/urandom 2>/dev/null | tr -d ' \n' || printf '%s' "$$")"
      request_file="$REQUESTS_DIR/$req_id.req"
      response_file="$RESPONSES_DIR/$req_id.resp"
      waited=0

      mkdir -p "$REQUESTS_DIR" "$RESPONSES_DIR"
      {
        printf 'command=materialize\n'
        printf 'installable=%s\n' "$installable"
      } > "$request_file"

      while [ "$waited" -lt "$TIMEOUT" ]; do
        if [ -f "$response_file" ]; then
          return 0
        fi
        sleep 1
        waited=$((waited + 1))
      done

      echo "[agent] nix tool helper timed out waiting for '$installable'" >&2
      exit 1
    }

    load_response() {
      response_file="$1"
      status=""
      installable=""
      out_path=""
      bin_path=""
      message=""

      while IFS='=' read -r key value; do
        case "$key" in
          status) status="$value" ;;
          installable) installable="$value" ;;
          out_path) out_path="$value" ;;
          bin_path) bin_path="$value" ;;
          message) message="$value" ;;
        esac
      done < "$response_file"

      rm -f "$response_file"

      if [ "$status" != "ok" ]; then
        echo "[agent] nix tool helper failed for '$installable': $message" >&2
        exit 1
      fi
    }

    [ "$#" -ge 2 ] || usage
    command="$1"
    shift
    installable="$1"
    shift

    [ -d "$BRIDGE_DIR" ] || {
      echo "[agent] nix tool helper bridge is unavailable at $BRIDGE_DIR" >&2
      exit 1
    }

    helper_request "$installable"
    load_response "$response_file"

    case "$command" in
      add)
        if [ -n "$bin_path" ]; then
          printf '%s\n' "$bin_path"
        else
          printf '%s\n' "$out_path"
        fi
        ;;
      env)
        [ -n "$bin_path" ] || exit 0
        printf 'export PATH="%s:$PATH"\n' "$bin_path"
        ;;
      run)
        [ "$#" -ge 1 ] || usage
        [ "$1" = "--" ] || usage
        shift
        [ "$#" -ge 1 ] || usage
        if [ -n "$bin_path" ]; then
          PATH="$bin_path:$PATH"
        fi
        exec "$@"
        ;;
      *)
        usage
        ;;
    esac
  '';

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
      pkgs.direnv
      pkgs.nix
      pkgs.nix-direnv
      direnvEtc
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
