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

  agentCompat = pkgs.writeShellScriptBin "agent-compat" ''
    #!/usr/bin/env bash
    set -euo pipefail

    nix_real="${pkgs.nix}/bin/nix"
    nix_shell_real="${pkgs.nix}/bin/nix-shell"

    usage() {
      echo "usage: agent-compat <command-not-found|run-command|nix-wrapper|nix-shell-wrapper> ..." >&2
      exit 1
    }

    resolve_wrapper_real() {
      local wrapper_name="$1"
      local wrapper_path="/bin/$wrapper_name"

      if [ ! -e "$wrapper_path" ]; then
        return 0
      fi

      readlink -f "$wrapper_path" 2>/dev/null || printf '%s\n' "$wrapper_path"
    }

    find_existing_command() {
      local command_name="$1"
      local wrapper_name="${2:-}"
      local wrapper_real=""
      local candidate=""
      local candidate_real=""
      local path_dir=""

      if [ -n "$wrapper_name" ]; then
        wrapper_real="$(resolve_wrapper_real "$wrapper_name")"
      fi

      IFS=':' read -r -a path_entries <<< "${PATH:-}"
      for path_dir in "${path_entries[@]}"; do
        [ -n "$path_dir" ] || path_dir="."
        candidate="$path_dir/$command_name"
        [ -x "$candidate" ] || continue

        candidate_real="$(readlink -f "$candidate" 2>/dev/null || printf '%s\n' "$candidate")"
        if [ -z "$wrapper_real" ] || [ "$candidate_real" != "$wrapper_real" ]; then
          printf '%s\n' "$candidate"
          return 0
        fi
      done

      return 1
    }

    installable_for_command() {
      local command_name="$1"

      case "$command_name" in
        docker)
          printf '%s\n' 'nixpkgs#docker-client'
          ;;
        docker-compose)
          printf '%s\n' 'nixpkgs#docker-compose'
          ;;
        podman)
          printf '%s\n' 'nixpkgs#podman'
          ;;
        *)
          if printf '%s\n' "$command_name" | grep -Eq '^[A-Za-z0-9._+-]+$'; then
            printf 'nixpkgs#%s\n' "$command_name"
          else
            return 1
          fi
          ;;
      esac
    }

    resolve_bin_dir() {
      local resolved_path="$1"
      local first_exec=""

      if [ -d "$resolved_path" ]; then
        first_exec="$(find "$resolved_path" -mindepth 1 -maxdepth 1 -type f -perm -111 2>/dev/null | head -n1 || true)"
        if [ -n "$first_exec" ]; then
          printf '%s\n' "$resolved_path"
          return 0
        fi
      fi

      if [ -d "$resolved_path/bin" ]; then
        first_exec="$(find "$resolved_path/bin" -mindepth 1 -maxdepth 1 -type f -perm -111 2>/dev/null | head -n1 || true)"
        if [ -n "$first_exec" ]; then
          printf '%s\n' "$resolved_path/bin"
          return 0
        fi
      fi

      return 1
    }

    materialize_installable_bin_dir() {
      local installable="$1"
      local resolved_path=""

      [ "''${AGENT_NIX_TOOL_HELPER:-1}" = "1" ] || return 1
      command -v agent-nix-tool >/dev/null 2>&1 || return 1

      resolved_path="$(agent-nix-tool add "$installable" 2>/dev/null)" || return 1
      resolve_bin_dir "$resolved_path"
    }

    build_path_prefix() {
      local installable=""
      local bin_dir=""
      local path_prefix=""

      for installable in "$@"; do
        bin_dir="$(materialize_installable_bin_dir "$installable")" || return 1
        path_prefix="${path_prefix:+$path_prefix:}$bin_dir"
      done

      printf '%s\n' "$path_prefix"
    }

    run_materialized_command() {
      local command_name="$1"
      shift

      local existing_path=""
      local installable=""
      local bin_dir=""

      existing_path="$(find_existing_command "$command_name" "$command_name" || true)"
      if [ -n "$existing_path" ]; then
        exec "$existing_path" "$@"
      fi

      installable="$(installable_for_command "$command_name" || true)"
      if [ -z "$installable" ]; then
        exit 127
      fi

      bin_dir="$(materialize_installable_bin_dir "$installable" || true)"
      if [ -z "$bin_dir" ] || [ ! -x "$bin_dir/$command_name" ]; then
        echo "[agent] could not materialize '$command_name' from $installable" >&2
        exit 127
      fi

      exec "$bin_dir/$command_name" "$@"
    }

    run_with_installables() {
      local installables=()
      local path_prefix=""

      while [ "$#" -gt 0 ]; do
        case "$1" in
          --)
            shift
            break
            ;;
          *)
            installables+=( "$1" )
            shift
            ;;
        esac
      done

      [ "''${#installables[@]}" -gt 0 ] || return 1
      [ "$#" -gt 0 ] || return 1

      path_prefix="$(build_path_prefix "''${installables[@]}")" || return 1
      PATH="$path_prefix:$PATH" exec "$@"
    }

    shell_with_installables() {
      local installables=( "$@" )
      local path_prefix=""
      local shell_cmd="''${SHELL:-/bin/bash}"

      [ "''${#installables[@]}" -gt 0 ] || return 1

      path_prefix="$(build_path_prefix "''${installables[@]}")" || return 1
      PATH="$path_prefix:$PATH" exec "$shell_cmd"
    }

    handle_nix_shell() {
      local passthrough=()
      local installables=()
      local saw_shell="0"

      while [ "$#" -gt 0 ]; do
        case "$1" in
          shell)
            saw_shell="1"
            shift
            break
            ;;
          --extra-experimental-features)
            [ "$#" -ge 2 ] || exec "$nix_real" "''${passthrough[@]}" "$@"
            passthrough+=( "$1" "$2" )
            shift 2
            ;;
          --option)
            [ "$#" -ge 3 ] || exec "$nix_real" "''${passthrough[@]}" "$@"
            passthrough+=( "$1" "$2" "$3" )
            shift 3
            ;;
          *)
            exec "$nix_real" "''${passthrough[@]}" "$@"
            ;;
        esac
      done

      [ "$saw_shell" = "1" ] || exec "$nix_real" "''${passthrough[@]}" "$@"
      while [ "$#" -gt 0 ]; do
        case "$1" in
          --command|-c)
            shift
            [ "$#" -gt 0 ] || exec "$nix_real" "''${passthrough[@]}" shell "''${installables[@]}"
            [ "''${#installables[@]}" -gt 0 ] || exec "$nix_real" "''${passthrough[@]}" shell "$@"
            run_with_installables "''${installables[@]}" -- "$@"
            ;;
          --)
            shift
            [ "$#" -gt 0 ] || exec "$nix_real" "''${passthrough[@]}" shell "''${installables[@]}" --
            [ "''${#installables[@]}" -gt 0 ] || exec "$nix_real" "''${passthrough[@]}" shell -- "$@"
            run_with_installables "''${installables[@]}" -- "$@"
            ;;
          -*)
            exec "$nix_real" "''${passthrough[@]}" shell "$@"
            ;;
          *)
            installables+=( "$1" )
            shift
            ;;
        esac
      done

      [ "''${#installables[@]}" -gt 0 ] || exec "$nix_real" "''${passthrough[@]}" shell
      shell_with_installables "''${installables[@]}"
    }

    handle_legacy_nix_shell() {
      local packages=()
      local shell_command=""

      [ "$#" -gt 0 ] || exec "$nix_shell_real"
      [ "$1" = "-p" ] || exec "$nix_shell_real" "$@"
      shift

      while [ "$#" -gt 0 ]; do
        case "$1" in
          --run|--command)
            [ "$#" -ge 2 ] || exec "$nix_shell_real" -p "''${packages[@]}" "$@"
            shell_command="$2"
            shift 2
            [ "$#" -eq 0 ] || exec "$nix_shell_real" -p "''${packages[@]}" "$@"
            ;;
          --)
            shift
            [ "$#" -gt 0 ] || exec "$nix_shell_real" -p "''${packages[@]}" --
            run_with_installables "''${packages[@]/#/nixpkgs#}" -- "$@"
            ;;
          -*)
            exec "$nix_shell_real" -p "''${packages[@]}" "$@"
            ;;
          *)
            packages+=( "$1" )
            shift
            ;;
        esac
      done

      [ "''${#packages[@]}" -gt 0 ] || exec "$nix_shell_real"
      if [ -n "$shell_command" ]; then
        local path_prefix=""
        path_prefix="$(build_path_prefix "''${packages[@]/#/nixpkgs#}")" || exit 1
        PATH="$path_prefix:$PATH" exec /bin/sh -lc "$shell_command"
      fi

      shell_with_installables "''${packages[@]/#/nixpkgs#}"
    }

    command_name="''${1:-}"
    shift || true

    case "$command_name" in
      command-not-found)
        [ "$#" -ge 1 ] || exit 127
        run_materialized_command "$@"
        ;;
      run-command)
        [ "$#" -ge 1 ] || usage
        run_materialized_command "$@"
        ;;
      nix-wrapper)
        handle_nix_shell "$@"
        ;;
      nix-shell-wrapper)
        handle_legacy_nix_shell "$@"
        ;;
      *)
        usage
        ;;
    esac
  '';

  mkCompatWrapper =
    name: subcommand:
    pkgs.writeShellScriptBin name ''
      #!/usr/bin/env bash
      set -euo pipefail
      exec /bin/agent-compat ${subcommand} "$@"
    '';

  agentShellEnv = pkgs.writeTextDir "etc/agent-shell-env.sh" ''
    if [ -n "''${BASH_VERSION:-}" ] && command -v agent-compat >/dev/null 2>&1; then
      command_not_found_handle() {
        /bin/agent-compat command-not-found "$@" 2>/dev/null && return 0
        printf '%s: command not found\n' "$1" >&2
        return 127
      }
    fi
  '';

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
