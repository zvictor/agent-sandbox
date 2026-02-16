args@{ shared ? null, projectNixDir ? null, projectDevPackagesFile ? null, projectLockedPkgsFile ? null, ... }:

let
  normalizePath = value:
    if value == null then null
    else if builtins.isPath value then value
    else if builtins.isString value && value != "" then /. + value
    else null;

  envPath = name:
    let value = builtins.getEnv name;
    in if value == "" then null else normalizePath value;

  pkgsArg = if args ? pkgs then args.pkgs else null;
  unstableArg = if args ? unstable then args.unstable else null;

  projectRootEnvPath = envPath "AGENT_PROJECT_ROOT";
  pwdEnvPath = envPath "PWD";
  projectNixDirEnvPath = envPath "AGENT_PROJECT_NIX_DIR";
  projectNixDirPath =
    normalizePath (
      if projectNixDir != null then projectNixDir
      else if projectNixDirEnvPath != null then projectNixDirEnvPath
      else if projectRootEnvPath != null then "${toString projectRootEnvPath}/nix"
      else if pwdEnvPath != null then "${toString pwdEnvPath}/nix"
      else null
    );
  projectDevPackagesEnvPath = envPath "AGENT_PROJECT_DEV_PACKAGES_FILE";
  projectLockedPkgsEnvPath = envPath "AGENT_PROJECT_LOCKED_PKGS_FILE";
  projectDevPackagesPath =
    normalizePath (
      if projectDevPackagesFile != null then projectDevPackagesFile
      else if projectDevPackagesEnvPath != null then projectDevPackagesEnvPath
      else if projectNixDirPath != null then "${toString projectNixDirPath}/dev-packages.nix"
      else null
    );
  projectLockedPkgsPath =
    normalizePath (
      if projectLockedPkgsFile != null then projectLockedPkgsFile
      else if projectLockedPkgsEnvPath != null then projectLockedPkgsEnvPath
      else if projectNixDirPath != null then "${toString projectNixDirPath}/locked-pkgs.nix"
      else null
    );
  projectLockedPkgsPathText =
    if projectLockedPkgsPath == null then "(unset)"
    else toString projectLockedPkgsPath;
  projectDevPackagesPathText =
    if projectDevPackagesPath == null then "(unset)"
    else toString projectDevPackagesPath;

  locked = if pkgsArg != null && unstableArg != null
    then { pkgs = pkgsArg; unstable = unstableArg; }
    else if projectLockedPkgsPath != null && builtins.pathExists projectLockedPkgsPath
      then import projectLockedPkgsPath { }
      else builtins.throw ''
        agent-sandbox: missing project locked pkgs file.
        Expected AGENT_PROJECT_LOCKED_PKGS_FILE at: ${projectLockedPkgsPathText}
        Set AGENT_PROJECT_ROOT (or AGENT_PROJECT_NIX_DIR / AGENT_PROJECT_LOCKED_PKGS_FILE) from the host project wrapper.
      '';

  pkgsFinal = if pkgsArg != null then pkgsArg else locked.pkgs;
  unstableFinal = if unstableArg != null then unstableArg else locked.unstable;

  sharedPackages = if shared != null
    then shared
    else if projectDevPackagesPath != null && builtins.pathExists projectDevPackagesPath
      then import projectDevPackagesPath { pkgs = pkgsFinal; unstable = unstableFinal; }
      else builtins.throw ''
        agent-sandbox: missing project dev packages file.
        Expected AGENT_PROJECT_DEV_PACKAGES_FILE at: ${projectDevPackagesPathText}
        Set AGENT_PROJECT_ROOT (or AGENT_PROJECT_NIX_DIR / AGENT_PROJECT_DEV_PACKAGES_FILE) from the host project wrapper.
      '';

  devPackages = sharedPackages.devPackages;
  helpers = with pkgsFinal.dockerTools; [ usrBinEnv binSh caCertificates fakeNss ];

  # Git wrapper that blocks commands with side effects
  gitWrapper = pkgsFinal.writeShellScriptBin "git" ''
    #!/bin/sh
    set -e

    # Allow bypassing the sandbox when GIT_ALLOW is set
    if [ -n "''${GIT_ALLOW:-}" ]; then
      exec ${pkgsFinal.git}/bin/git "$@"
    fi

    # List of allowed safe git commands (prefix matching)
    SAFE_COMMANDS="clone|fetch|status|diff|log|show|branch|ls-files|rev-parse|describe|ls-tree|cat-file|blame|grep|reflog|config|remote|tag|for-each-ref|rev-list|shortlog|symbolic-ref|name-rev|merge-base"

    # Resolve the git subcommand (first non-flag argument)
    SUBCOMMAND=""

    while [ "$#" -gt 0 ]; do
      arg="$1"
      case "$arg" in
        -C|--git-dir|--work-tree|-c)
          shift 2 ;;        # skip flag + its value
        --*) shift ;;       # skip long flag
        -*)  shift ;;       # skip short flag(s)
        *)   SUBCOMMAND="$arg"; break ;;
      esac
    done

    # Allow if no subcommand (just "git")
    if [ -z "$SUBCOMMAND" ]; then
      exec ${pkgsFinal.git}/bin/git "$@"
    fi

    # Check if it's a safe command using prefix matching
    if echo "$SUBCOMMAND" | grep -qE "^($SAFE_COMMANDS)"; then
      exec ${pkgsFinal.git}/bin/git "$@"
    else
      echo "Error: git $SUBCOMMAND is blocked (side effects not allowed)" >&2
      echo "Allowed commands: status, diff, log, show, branch, ls-files, rev-parse, describe, ls-tree, cat-file, blame, grep, reflog, config, remote, tag" >&2
      exit 1
    fi
  '';


  tools = {
    codex = { pkg = "@openai/codex"; bin = "codex"; latest = true; };
    opencode = { pkg = "opencode-ai"; bin = "opencode"; };
    claude = { pkg = "@anthropic-ai/claude-code"; bin = "claude"; };
  };


  mkBunToolLauncher = { name, pkg, bin ? name, latest ? false }:
    let
      latestFlag = if latest then "1" else "0";
    in pkgsFinal.writeShellScriptBin name ''
      #!/bin/sh
      set -euo pipefail

      CACHE_DIR="''${TOOL_CACHE:-/cache}/${name}"
      mkdir -p "$CACHE_DIR"

      if [ ! -f "$CACHE_DIR/package.json" ]; then
        (cd "$CACHE_DIR" && bun init -y >/dev/null)
      fi

      pkg_json="$CACHE_DIR/node_modules/${pkg}/package.json"

      if [ "${latestFlag}" = "1" ]; then
        latest_version=$(npm view ${pkg} version 2>/dev/null | head -n1)
        if [ -z "$latest_version" ]; then
          echo "Failed to determine latest ${pkg} version" >&2
          exit 1
        fi

        current_version=""
        if [ -f "$pkg_json" ]; then
          current_version=$(node -p "require('$pkg_json').version")
          echo "${pkg} is cached as version ''${current_version:-unknown}" >&2
        fi

        if [ "$current_version" != "$latest_version" ]; then
          echo "Installing ${pkg}@$latest_version (latest) inside sandbox cache..." >&2
          (cd "$CACHE_DIR" && bun add "${pkg}@$latest_version" >/dev/null)
        fi
      else
        if [ ! -f "$pkg_json" ]; then
          echo "Installing ${pkg} inside sandbox cache..." >&2
          (cd "$CACHE_DIR" && bun add "${pkg}" >/dev/null)
        fi
      fi

      exec "$CACHE_DIR/node_modules/.bin/${bin}" "$@"
    '';

  toolsWithName = builtins.mapAttrs (name: tool: tool // { inherit name; }) tools;
  toolLaunchers = builtins.attrValues (builtins.mapAttrs (_: tool: mkBunToolLauncher tool) toolsWithName);

  # Provide /etc/direnv/direnvrc via buildEnv (avoid writing /etc in extraCommands).
  direnvEtc = pkgsFinal.runCommand "direnv-etc" {} ''
    mkdir -p $out/etc/direnv
    ln -s ${pkgsFinal.nix-direnv}/share/nix-direnv/direnvrc \
      $out/etc/direnv/direnvrc
  '';

  imageRoot = pkgsFinal.buildEnv {
    name = "agent-rootfs";
    paths =
      [
        gitWrapper
        pkgsFinal.nix
        pkgsFinal.direnv
        pkgsFinal.nix-direnv
        direnvEtc
        unstableFinal.podman-compose
        pkgsFinal.bashInteractive
        pkgsFinal.busybox
        pkgsFinal.docker
        pkgsFinal.docker-compose
        pkgsFinal.perl
        pkgsFinal.python3
        pkgsFinal.uv
        pkgsFinal.curl
        pkgsFinal.wget
        pkgsFinal.jq
        pkgsFinal.fx
      ]
      ++ helpers
      ++ devPackages
      ++ toolLaunchers;

    pathsToLink = [
      "/bin"
      "/usr/bin"
      "/lib"
      "/libexec"
      "/share"
      "/etc"
    ];
    ignoreCollisions = true; # Allow gitWrapper to override real git
  };

  baseImageName = "agent-base";
  baseImageTag  = "latest";
  baseImageRef  = "${baseImageName}:${baseImageTag}";


  toolsImage = pkgsFinal.dockerTools.buildImage {
    name = baseImageName;
    tag  = baseImageTag;

    copyToRoot = imageRoot;
    includeNixDB = true;

    extraCommands = ''
      mkdir -p lib64
      ln -sf ${pkgsFinal.glibc.out}/lib/ld-linux-x86-64.so.2 lib64/ld-linux-x86-64.so.2

      mkdir -p nix/store nix/var/nix nix/var/log/nix nix/var/db
      rm -rf nix/var/nix/profiles nix/var/nix/gcroots
      ln -s /cache/nix/profiles nix/var/nix/profiles
      ln -s /cache/nix/gcroots nix/var/nix/gcroots
      chmod -R 0777 nix

      # Cache mountpoint (volume will be mounted here at runtime)
      mkdir -p nixcache
      chmod 0777 nixcache

      mkdir -p tmp
      chmod 1777 tmp
    '';

    config = {
      WorkingDir = "/workspace";
      Entrypoint = [ "/bin/codex" ];
      Env = [
        "PATH=/bin:/usr/bin:/usr/local/bin:/workspace/node_modules/.bin:${pkgsFinal.lib.makeBinPath devPackages}:${pkgsFinal.docker}/bin:${pkgsFinal.bashInteractive}/bin"
        "HOME=/cache"
        "XDG_CACHE_HOME=/cache"
        "TOOL_CACHE=/cache"
        "CODEX_CACHE=/cache"
        "TESTCONTAINERS_RYUK_DISABLED=true"
        "NIX_PATH=nixpkgs=${pkgsFinal.path}"

        # Base Nix config (wrapper augments this at runtime).
        "NIX_CONFIG=sandbox = false\nsubstituters = https://cache.nixos.org\ntrusted-public-keys = cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY="
      ];
    };
  };

  mkToolWrapper = toolName:
    pkgsFinal.writeScriptBin toolName ''
      #!${pkgsFinal.bash}/bin/bash
      set -euo pipefail

      runtime="''${CODEX_RUNTIME:-podman}"
      if ! command -v "$runtime" >/dev/null 2>&1; then
        echo "Requested runtime '$runtime' is not available" >&2
        exit 1
      fi

      cache_dir="''${XDG_CACHE_HOME:-$HOME/.cache}/agent-cli"
      mkdir -p "$cache_dir"
      mkdir -p "$cache_dir/nix/profiles" "$cache_dir/nix/gcroots" "$cache_dir/nix/var/log"
      mkdir -p "$cache_dir/.config/direnv"

      # Ensure direnv loads nix-direnv (overrides stdlib's use_nix implementation).
      cat > "$cache_dir/.config/direnv/direnvrc" <<'EOF'
source /etc/direnv/direnvrc
EOF

      image_archive="${toolsImage}"
      base_ref="${baseImageRef}"
      entrypoint="/bin/${toolName}"

      host_config=""
      container_config=""
      profile_var=""
      profile_dir="profiles"
      profile_base=""
      profile_target=""
      config_env_var=""

      case "${toolName}" in
        codex)
          host_config="''${CODEX_HOME:-''${HOME}/.codex}"
          container_config="/config/.codex"
          profile_var="CODEX_PROFILE"
          profile_target="auth.json"
          config_env_var="CODEX_HOME"
          profile_base="''${HOME}/.codex/profiles"
          ;;
        opencode)
          host_config="''${OPENCODE_CONFIG_DIR:-''${HOME}/.config/opencode}"
          container_config="/config/.opencode"
          profile_var="OPENCODE_PROFILE"
          profile_target="opencode.json"
          config_env_var="OPENCODE_CONFIG_DIR"
          ;;
        claude)
          host_config="''${CLAUDE_CONFIG_DIR:-''${HOME}/.claude}"
          container_config="/config/.claude"
          profile_var="CLAUDE_PROFILE"
          profile_target=".credentials.json"
          config_env_var="CLAUDE_CONFIG_DIR"
          ;;
      esac

      # ---- Compute CODEX_NAME_PREFIX/worktree tag (simple rules) ----
      # 1) If worktree: use origin URL repo name
      # 2) Else if regular git: use `git rev-parse --git-dir` and take its parent folder name
      # 3) Else: use the parent folder name of $PWD
      name_prefix=""
      worktree_tag=""
      git_dir=""
      common_dir=""

      if command -v git >/dev/null 2>&1 && git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        git_dir="$(git rev-parse --path-format=absolute --git-dir 2>/dev/null || true)"
        common_dir="$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)"

        branch_name="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
        if [ -n "$branch_name" ] && [ "$branch_name" != "HEAD" ]; then
          worktree_tag="$branch_name"
        fi

        origin_url="$(git config --get remote.origin.url 2>/dev/null || true)"
        if [ -n "$origin_url" ]; then
          name_prefix="''${origin_url##*/}"
          name_prefix="''${name_prefix##*:}"
          name_prefix="''${name_prefix%.git}"
        fi

        if [ -n "$git_dir" ] && [ -n "$common_dir" ] && [ "$git_dir" != "$common_dir" ]; then
          if [ -z "$worktree_tag" ]; then
            worktree_tag="$(basename "$git_dir")"
          fi
        fi

        if [ -z "$name_prefix" ] && [ -n "$common_dir" ]; then
          repo_root="$(dirname "$common_dir")"
          name_prefix="$(basename "$repo_root")"
        fi
      fi

      if [ -z "$name_prefix" ]; then
        name_prefix="$(basename "$(dirname "$PWD")")"
      fi

      if [ -z "$worktree_tag" ]; then
        worktree_tag="$(basename "$PWD")"
      fi

      # sanitize a bit for container/image naming
      name_prefix="$(echo "$name_prefix" | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9._-')"
      name_prefix="''${name_prefix:-agent}"

      worktree_tag="$(echo "$worktree_tag" | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9._-')"
      worktree_tag="''${worktree_tag:-latest}"

      image_name="agent-''${name_prefix}"
      image_tag="''${worktree_tag}"
      image_ref="''${image_name}:''${image_tag}"
      stamp_key="$(printf '%s_%s' "''${image_name}" "''${image_tag}" | tr '/:' '__')"
      stamp_file="$cache_dir/image.''${stamp_key}.stamp"

      stamp_archive=""
      stamp_image_id=""
      if [ -f "$stamp_file" ]; then
        while IFS='=' read -r key val; do
          case "$key" in
            archive) stamp_archive="$val" ;;
            image_id) stamp_image_id="$val" ;;
          esac
        done < "$stamp_file"
      fi

      image_id=""
      if [ "$stamp_archive" = "$image_archive" ] && [ -n "$stamp_image_id" ] && "$runtime" image inspect "$stamp_image_id" >/dev/null 2>&1; then
        image_id="$stamp_image_id"
      else
        echo "Refreshing $image_ref with $runtime..." >&2
        load_output="$("$runtime" load -i "$image_archive")"
        image_id="$(printf '%s\n' "$load_output" | sed -n 's/.*\\(sha256:[0-9a-f]\\{64\\}\\).*/\\1/p' | head -n1)"
        if [ -z "$image_id" ]; then
          image_id="$("$runtime" image inspect "$base_ref" --format '{{.Id}}' 2>/dev/null || true)"
        fi
        if [ -z "$image_id" ]; then
          echo "Failed to determine loaded image id for $image_ref" >&2
          exit 1
        fi
        printf 'archive=%s\nimage_id=%s\n' "$image_archive" "$image_id" >"$stamp_file"
      fi

      "$runtime" tag "$image_id" "$image_ref" >/dev/null 2>&1 || "$runtime" tag "$image_id" "$image_ref"

      user_id=$(id -u)
      group_id=$(id -g)

      # Allowlisted env prefixes to pass through from host to container.
      default_pass_env_prefixes=$'DEPLOYMENT_STAGE\nCODEX_PROFILE\nOPENCODE_PROFILE\nCLAUDE_PROFILE\nOPENCODE_\nCLAUDE_\nTESTCONTAINERS_HOST_OVERRIDE\nTESTCONTAINERS_RYUK_DISABLED\nDEBUG\nGIT_ALLOW'
      pass_env_prefixes="''${AGENT_PASS_ENV_PREFIXES:-$default_pass_env_prefixes}"

      suffix=""
      if command -v shuf >/dev/null 2>&1 && [ -r /usr/share/dict/words ]; then
        suffix="$(shuf -n 1 /usr/share/dict/words | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9' | head -c 12 || true)"
      fi
      suffix="''${suffix:-''${RANDOM}''${RANDOM}}"
      container_base="''${image_name}-''${image_tag}"
      container_name="''${container_base}-''${suffix}"
      container_name="''${container_name:0:63}"

      # Nix Binary cache:
      # - If AGENT_NIX_BINCACHE_DIR is set, bind-mount it read-only (prepopulated by host).
      # - Else fall back to a shared named volume (writable by the sandbox).
      cache_mount_args=()
      if [ -n "''${AGENT_NIX_BINCACHE_DIR:-}" ]; then
        cache_mount_args+=( -v "''${AGENT_NIX_BINCACHE_DIR}:/nixcache:ro" )
      else
        cache_mount_args+=( -v "agent-nix-bincache:/nixcache:rw" )
      fi

      nix_config="sandbox = false
substituters = https://cache.nixos.org
trusted-public-keys = cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY"

      # Enable local binary cache substituter.
      if [ "''${AGENT_USE_LOCAL_BINCACHE:-1}" = "1" ]; then
        nix_config="$nix_config
extra-substituters = file:///nixcache"
      fi

      # Optional: allow unsigned local substitutes (handy for host-prepopulated caches
      # that weren't signed). Default is off.
      if [ "''${AGENT_LOCAL_BINCACHE_ALLOW_UNSIGNED:-0}" = "1" ]; then
        nix_config="$nix_config
require-sigs = false"
      fi

      args=(
        --rm
        --network=host
        --name "''${container_name}"
        -v "$cache_dir:/cache"
        -v "''${AGENT_WORKSPACE_HOST_PATH:-$PWD}:/workspace:rw"
        "''${cache_mount_args[@]}"
        --tmpfs /tmp:rw,exec,nosuid,nodev,size=512m
        -w /workspace
        -e "HOME=/cache"
        -e "XDG_CACHE_HOME=/cache"
        -e "TOOL_CACHE=/cache"
        -e "CODEX_CACHE=/cache"
        -e "WORKSPACE_HOST_PATH=''${AGENT_WORKSPACE_HOST_PATH:-$PWD}"
        -e "NIX_CONFIG=$nix_config"
      )

      args+=( -e "CODEX_NAME_PREFIX=$name_prefix" )

      if [ -n "''${AGENT_EXTRA_ENV:-}" ]; then
        while IFS= read -r env_spec; do
          [ -z "$env_spec" ] && continue
          args+=( -e "$env_spec" )
        done < <(printf '%s\n' "''${AGENT_EXTRA_ENV}" | tr ',' '\n' | sed '/^$/d')
      fi

      # Auto-mount directories discovered by name in current/ancestor paths.
      if [ -n "''${AGENT_AUTO_MOUNT_DIRS:-}" ]; then
        while IFS= read -r mount_name; do
          [ -z "$mount_name" ] && continue
          mount_dir=""
          dir="$PWD"
          while [ "$dir" != "/" ]; do
            if [ -d "$dir/$mount_name" ]; then
              mount_dir="$dir/$mount_name"
              break
            fi
            dir="$(dirname "$dir")"
          done
          if [ -n "$mount_dir" ]; then
            args+=( -v "$mount_dir:/$mount_name:rw" )
          fi
        done < <(printf '%s\n' "''${AGENT_AUTO_MOUNT_DIRS}" | tr ',' '\n' | sed '/^$/d')
      fi

      # Extra manual mount specs in host:container[:options] format.
      if [ -n "''${AGENT_EXTRA_MOUNTS:-}" ]; then
        while IFS= read -r mount_spec; do
          [ -z "$mount_spec" ] && continue
          args+=( -v "$mount_spec" )
        done < <(printf '%s\n' "''${AGENT_EXTRA_MOUNTS}" | tr ',' '\n' | sed '/^$/d')
      fi

      # Worktree .git indirection support
      if [ -f "$PWD/.git" ]; then
        gitdir_line="$(head -n1 "$PWD/.git" || true)"
        case "$gitdir_line" in
          gitdir:\ ../main/.git/*)
            # Host path to main worktree adjacent to this worktree:
            host_main="$(cd "$PWD/../main" && pwd -P)"
            # Create the same layout in the container: /workspace/../main
            args+=( -v "$host_main:/workspace/../main:rw" )
            ;;
        esac
      fi

      # If XDG_RUNTIME_DIR is set and the podman socket exists, mount it.
      if [ -n "''${XDG_RUNTIME_DIR:-}" ]; then
        sock="''${XDG_RUNTIME_DIR}/podman/podman.sock"
        if [ -S "''${sock}" ]; then
          args+=( -v "''${sock}:/var/run/docker.sock" )
          args+=( -v "''${sock}:/run/podman/podman.sock" )
          args+=( -e "DOCKER_HOST=unix:///var/run/docker.sock" )
          args+=( -e "CONTAINER_HOST=unix:///run/podman/podman.sock" )
        fi
      fi

      # Inject allowlisted env vars from host.
      while IFS='=' read -r key val; do
        while IFS= read -r prefix; do
          case "$key" in
            "$prefix"*)
              args+=( -e "''${key}=''${val}" )
              break
              ;;
          esac
        done <<< "$pass_env_prefixes"
      done < <(env)

      # Pass exact env names (comma-separated) when an exact match is needed.
      if [ -n "''${AGENT_PASS_ENV_NAMES:-}" ]; then
        while IFS= read -r env_name; do
          [ -z "$env_name" ] && continue
          if [ -n "''${!env_name+x}" ]; then
            args+=( -e "$env_name=''${!env_name}" )
          fi
        done < <(printf '%s\n' "''${AGENT_PASS_ENV_NAMES}" | tr ',' '\n' | sed '/^$/d')
      fi

      if [ "$runtime" = podman ]; then
        args+=( --userns=keep-id )
      else
        args+=( --user "''${user_id}:''${group_id}" )
      fi

      if [ -n "$host_config" ] && [ -d "$host_config" ]; then
        args+=( -v "$host_config:$container_config:rw" )
        if [ -n "$config_env_var" ]; then
          args+=( -e "''${config_env_var}=$container_config" )
        fi

        if [ -n "$profile_var" ]; then
          profile_name="''${!profile_var:-}"
          if [ -n "$profile_name" ]; then
            if [ -n "$profile_base" ]; then
              profile_path="$profile_base/$profile_name.json"
            else
              profile_path="$host_config/$profile_dir/$profile_name.json"
            fi
            if [ -f "$profile_path" ]; then
              args+=( -v "$profile_path:$container_config/$profile_target:rw" )
            else
              echo "ERROR: ''${profile_var} is set to ''${profile_name}' but profile not found at ''$profile_path'." >&2
              exit 1
            fi
          fi
        fi
      fi

      if [ "$runtime" = docker ] && [ -S "/var/run/docker.sock" ]; then
        args+=( -v "/var/run/docker.sock:/var/run/docker.sock" )
      fi

      if [ -t 0 ] && [ -t 1 ]; then
        args+=( -it )
      else
        args+=( -i )
      fi

      args+=( --entrypoint "$entrypoint" )
      args+=( "''${image_ref}" )
      if [ "$#" -gt 0 ]; then
        args+=( "$@" )
      fi

      printf "Running ${toolName} from $runtime: \033[1;30m$runtime run ''${args[*]}\033[0m\n\n" >&2
      exec "$runtime" run "''${args[@]}"
    '';

  toolWrappers = builtins.mapAttrs (name: _: mkToolWrapper name) toolsWithName;


in builtins.mapAttrs (_: wrapper: {
  image   = toolsImage;
  inherit wrapper;
}) toolWrappers
