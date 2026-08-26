{ pkgs, unstablePkgs, devPackages, nix2containerPkgs }:
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

  bubblewrapCompat = pkgs.runCommand "bubblewrap-compat" { } ''
    mkdir -p "$out/usr/bin"
    # Codex looks for the system bubblewrap binary at /usr/bin/bwrap when its
    # native sandbox is enabled.
    ln -s ${pkgs.bubblewrap}/bin/bwrap "$out/usr/bin/bwrap"
  '';

  libstdcCompat = pkgs.runCommand "libstdc-compat" { } ''
    mkdir -p "$out/usr/lib"
    cp -L ${pkgs.stdenv.cc.cc.lib}/lib/libstdc++.so.6 "$out/usr/lib/libstdc++.so.6"
    chmod 755 "$out/usr/lib/libstdc++.so.6"
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
    commandcode = {
      pkg = "command-code";
      bin = "cmd";
      latest = true;
    };
  };

  needCommand = pkgs.runCommand "need" { } ''
    install -Dm0755 ${../scripts/image/need.sh} "$out/bin/need"
  '';

  remoteScripts = pkgs.runCommand "agent-remote-scripts" { } ''
    install -Dm0755 ${../scripts/image/remote-entrypoint.sh} "$out/bin/agent-remote-entrypoint"
    install -Dm0755 ${../scripts/image/remote-dispatch.sh} "$out/bin/agent-remote-dispatch"
    install -Dm0755 ${../scripts/image/remote-shell.sh} "$out/bin/agent-remote-shell"
    install -Dm0755 ${../scripts/image/remote-codex.sh} "$out/bin/agent-remote-codex"
  '';

  firecrackerPodmanWrapper = pkgs.writeShellScriptBin "agent-firecracker-podman" ''
    set -eu

    podman_state=/cache/agent-firecracker-podman
    podman_root="$podman_state/root"
    podman_runroot=/run/agent-firecracker-podman
    podman_tmpdir="$podman_state/tmp"
    podman_network_config="$podman_state/networks"

    /agent-sudo/bin/sudo -n mkdir -p "$podman_root" "$podman_runroot" "$podman_tmpdir" "$podman_network_config"
    /agent-sudo/bin/sudo -n chmod 0700 "$podman_root" "$podman_runroot" "$podman_network_config"
    /agent-sudo/bin/sudo -n chmod 1777 "$podman_tmpdir"

    exec /agent-sudo/bin/sudo -n env TMPDIR="$podman_tmpdir" \
      ${pkgs.podman}/bin/podman \
      --storage-driver vfs \
      --root "$podman_root" \
      --runroot "$podman_runroot" \
      --network-config-dir "$podman_network_config" \
      "$@"
  '';

  containersPolicy = pkgs.writeTextDir "etc/containers/policy.json" ''
    {
      "default": [
        {
          "type": "insecureAcceptAnything"
        }
      ],
      "transports": {
        "docker-daemon": {
          "": [
            {
              "type": "insecureAcceptAnything"
            }
          ]
        }
      }
    }
  '';

  sudoPackage = pkgs.sudo.overrideAttrs (oldAttrs: {
    configureFlags = oldAttrs.configureFlags ++ [ "--without-pam" ];
    buildInputs = builtins.filter (pkg: pkg != pkgs.pam) (oldAttrs.buildInputs or [ ]);
  });

  sudoConfig = pkgs.runCommand "agent-sudo-config" { } ''
    mkdir -p "$out/etc/sudoers.d"
    cat > "$out/etc/sudoers" <<'EOF'
Defaults env_keep += "HOME XDG_CACHE_HOME TOOL_CACHE CODEX_CACHE AGENT_* CODEX_* CLAUDE_* OPENCODE_* OMP_* PI_* COMMANDCODE_*"
ALL ALL=(ALL:ALL) NOPASSWD:SETENV: ALL
EOF
    cp "$out/etc/sudoers" "$out/etc/sudoers.d/agent-sandbox"
    chmod 0440 "$out/etc/sudoers"
    chmod 0440 "$out/etc/sudoers.d/agent-sandbox"
  '';

  sudoRuntime = pkgs.runCommand "agent-sudo-runtime" { } ''
    mkdir -p "$out/agent-sudo/bin"
    cp -L ${sudoPackage}/bin/sudo "$out/agent-sudo/bin/sudo"
    cp -L ${sudoPackage}/bin/sudo "$out/agent-sudo/bin/sudoedit"
    mkdir -p "$out/nix-support"
    printf '%s\n' ${sudoPackage} > "$out/nix-support/agent-sudo-package"
  '';

  sudoImagePerms = [
    {
      path = sudoRuntime;
      regex = "agent-sudo/bin/sudo$";
      mode = "4755";
      uid = 0;
      gid = 0;
      uname = "root";
      gname = "root";
    }
    {
      path = sudoRuntime;
      regex = "agent-sudo/bin/sudoedit$";
      mode = "4755";
      uid = 0;
      gid = 0;
      uname = "root";
      gname = "root";
    }
  ];

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
        if [ -n "''${AGENT_CODEX_ROLLOUT_SOURCE_HOME:-}" ]; then
          ${pkgs.bun}/bin/bun ${../scripts/image/codex-state-migrate.ts}
        fi
      fi

      if [ "''${AGENT_NEED_BOOTSTRAP_INDEX:-1}" = "1" ] && command -v need >/dev/null 2>&1; then
        /bin/need bootstrap-index >/dev/null 2>&1 || true
      fi

      if [ ! -f "$CACHE_DIR/package.json" ]; then
        (cd "$CACHE_DIR" && ${pkgs.bun}/bin/bun init -y >/dev/null)
      fi

      pkg_json="$CACHE_DIR/node_modules/${pkg}/package.json"
      bin_path="$CACHE_DIR/node_modules/.bin/${bin}"
      requested_version=""
      if [ "${name}" = "codex" ]; then
        requested_version="''${AGENT_CODEX_VERSION:-}"
      fi

      if [ "$requested_version" = "latest" ]; then
        requested_version=""
      fi

      if [ -n "$requested_version" ]; then
        current_version=""
        if [ -f "$pkg_json" ]; then
          current_version=$(${pkgs.bun}/bin/bun --print "require('$pkg_json').version" 2>/dev/null || true)
          echo "${pkg} is cached as version ''${current_version:-unknown}" >&2
        fi

        if [ "$current_version" != "$requested_version" ] || [ ! -e "$bin_path" ]; then
          echo "Installing ${pkg}@$requested_version..." >&2
          (cd "$CACHE_DIR" && ${pkgs.bun}/bin/bun add --trust "${pkg}@$requested_version")
        fi
      elif [ "${latestFlag}" = "1" ]; then
        current_version=""
        if [ -f "$pkg_json" ]; then
          current_version=$(${pkgs.bun}/bin/bun --print "require('$pkg_json').version" 2>/dev/null || true)
          echo "${pkg} is cached as version ''${current_version:-unknown}" >&2
        fi

        latest_version="$((cd "$CACHE_DIR" && ${pkgs.bun}/bin/bun info ${pkg} version) 2>/dev/null | head -n1 || true)"
        if [ -z "$latest_version" ]; then
          if [ -z "$current_version" ]; then
            echo "Could not resolve latest ${pkg}; installing unpinned package..." >&2
            (cd "$CACHE_DIR" && ${pkgs.bun}/bin/bun add --trust "${pkg}")
          fi
        elif [ "$current_version" != "$latest_version" ]; then
          echo "Installing ${pkg}@$latest_version..." >&2
          (cd "$CACHE_DIR" && ${pkgs.bun}/bin/bun add --trust "${pkg}@$latest_version")
        fi
      else
        if [ ! -f "$pkg_json" ]; then
          echo "Installing ${pkg}..." >&2
          (cd "$CACHE_DIR" && ${pkgs.bun}/bin/bun add --trust "${pkg}")
        fi
      fi

      if [ ! -e "$bin_path" ]; then
        echo "Expected launcher missing after install: $bin_path" >&2
        exit 1
      fi

      # Prefer the package's own executable entrypoint when it is a shell or
      # native wrapper. Node shebang launchers should still run under Bun so
      # the image does not need a separate nodejs runtime.
      if [ -x "$bin_path" ]; then
        first_line="$(sed -n '1p' "$bin_path" 2>/dev/null || true)"
        case "$first_line" in
          '#!'*node*|'#!'*'/env '*node*)
            ;;
          *)
            exec "$bin_path" "$@"
            ;;
        esac
      fi

      exec ${pkgs.bun}/bin/bun "$bin_path" "$@"
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

    mkdir -p "$out/nixcache" "$out/tmp" "$out/var/tmp" "$out/config"
    mkdir -p "$out/proc" "$out/sys/fs/cgroup" "$out/dev/net"
    mkdir -p "$out/run" "$out/run/agent-container-api" "$out/run/agent-nix-helper" "$out/run/agent-path-guard" "$out/run/agent-runtime-receipts" "$out/run/host-services" "$out/run/secrets" "$out/var/run"
  '';

  imageBasePaths =
    [
      skeleton
      pkgs.git
      agentCompat
      pkgs.direnv
      pkgs.nix-direnv
      direnvEtc
      bashBin
      bubblewrapCompat
      libstdcCompat
      pkgs.coreutils
      pkgs.gnugrep
      pkgs.gnused
      pkgs.gawk
      pkgs.findutils
      pkgs.openssh
      pkgs.tmux
      pkgs.curl
      pkgs.wget
      pkgs.jq
      pkgs.fx
      pkgs.bun
      pkgs.iproute2
      pkgs.nix-index
    ]
    ++ helpers
    ++ devPackagesImage
    ++ toolLaunchers
    ++ compatWrappers
    ++ [ needCommand remoteScripts firecrackerPodmanWrapper containersPolicy sudoConfig sudoRuntime ];

  imageSpec = {
    name = "agent-base";
    tag = "latest";
    maxLayers = 120;

    copyToRoot = imageBasePaths;
    perms = sudoImagePerms;

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
        "NIX_PATH=nixpkgs=${unstablePkgs.path}"
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
      # Keep NSS files as real files for direct rootfs inspection/debugging.
      rm -f "$out/etc/passwd" "$out/etc/group" "$out/etc/nsswitch.conf"
      install -Dm0644 -T "${pkgs.dockerTools.fakeNss}/etc/passwd" "$out/etc/passwd"
      install -Dm0644 -T "${pkgs.dockerTools.fakeNss}/etc/group" "$out/etc/group"
      install -Dm0644 -T "${pkgs.dockerTools.fakeNss}/etc/nsswitch.conf" "$out/etc/nsswitch.conf"

      # Keep rootfs bind-mount targets as real nodes. crun is strict about
      # top-level symlink mount destinations in `podman --rootfs` containers.
      rm -rf "$out/agent-sudo"
      install -Dm0755 -T "${sudoRuntime}/agent-sudo/bin/sudo" "$out/agent-sudo/bin/sudo"
      install -Dm0755 -T "${sudoRuntime}/agent-sudo/bin/sudoedit" "$out/agent-sudo/bin/sudoedit"
      rm -f "$out/etc/sudo.conf" "$out/etc/sudoers" "$out/etc/sudoers.dist" "$out/etc/sudo_logsrvd.conf"
      : > "$out/etc/sudo.conf"
      install -Dm0440 -T "${sudoConfig}/etc/sudoers.d/agent-sandbox" "$out/etc/sudoers"

      # Keep common runtime mount destinations as normal directories, not
      # symlink chains.
      for d in \
        cache config nixcache tmp run run/agent-container-api run/agent-nix-helper run/agent-runtime-receipts run/secrets var var/run var/tmp \
        nix nix/store nix/var/nix nix/var/log/nix nix/var/db \
        proc sys sys/fs sys/fs/cgroup dev dev/net
      do
        rm -rf "$out/$d"
        mkdir -p "$out/$d"
      done
      chmod 1777 "$out/tmp" "$out/var/tmp"
      ln -sfn /cache/nix/profiles "$out/nix/var/nix/profiles"
      ln -sfn /cache/nix/gcroots "$out/nix/var/nix/gcroots"
    '';
  };

  streamImage = n2c.buildImage imageSpec;
}
