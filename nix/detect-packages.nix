{ pkgs, unstable, projectPkgs }:
let
  asList =
    value:
    if builtins.isList value then
      value
    else if builtins.isAttrs value && value ? devPackages then
      value.devPackages
    else
      builtins.throw ''
        agent-sandbox: package definition must evaluate to either:
        - a list of packages
        - or an attrset with `devPackages`
      '';

  firstExisting =
    paths:
    let
      found = builtins.filter (p: builtins.pathExists p) paths;
    in
    if found == [ ] then null else builtins.head found;

  packagesPath = firstExisting [
    "${projectPkgs}/packages.nix"
    "${projectPkgs}/nix/packages.nix"
  ];

  shellPath = firstExisting [
    "${projectPkgs}/shell.nix"
  ];

  fromPackages = asList (import packagesPath {
    inherit pkgs unstable;
  });

  # Resolve the project's own nixpkgs from its flake.lock (pure, no --impure needed)
  projectFlakeLockPath = "${projectPkgs}/flake.lock";
  hasProjectFlakeLock = builtins.pathExists projectFlakeLockPath;
  projectLockData = if hasProjectFlakeLock then builtins.fromJSON (builtins.readFile projectFlakeLockPath) else null;
  nixpkgsInputName = if projectLockData != null then projectLockData.root.inputs.nixpkgs or null else null;
  nixpkgsLocked = if nixpkgsInputName != null then projectLockData.nodes.${nixpkgsInputName}.locked or null else null;

  # Resolve from pinned fetchTarball (written by bash when no flake.lock exists)
  pinnedNixpkgsPath = "${projectPkgs}/.agent-sandbox-pinned-nixpkgs.json";
  hasPinnedNixpkgs = builtins.pathExists pinnedNixpkgsPath;
  pinnedNixpkgsData = if hasPinnedNixpkgs then builtins.fromJSON (builtins.readFile pinnedNixpkgsPath) else null;

  projectOwnPkgs =
    if nixpkgsLocked != null then
      let
        url = "https://github.com/${nixpkgsLocked.owner}/${nixpkgsLocked.repo}/archive/${nixpkgsLocked.rev}.tar.gz";
      in
      import (fetchTarball { inherit url; sha256 = nixpkgsLocked.narHash; }) { inherit (pkgs) system; }
    else if pinnedNixpkgsData != null then
      import (fetchTarball { inherit (pinnedNixpkgsData) url sha256; }) { inherit (pkgs) system; }
    else
      pkgs;

  fromShell =
    let
      shellExpr = import shellPath;
      # Pure flake evaluation cannot resolve defaults such as import <nixpkgs>.
      # The project contract always receives the nixpkgs instance resolved above.
      shellDrv =
        if builtins.isFunction shellExpr then shellExpr { pkgs = projectOwnPkgs; } else shellExpr;
      fromBuildInputs = shellDrv.buildInputs or [ ];
      fromNativeBuildInputs = shellDrv.nativeBuildInputs or [ ];
      fromPackagesAttr = shellDrv.packages or [ ];
      merged = fromBuildInputs ++ fromNativeBuildInputs ++ fromPackagesAttr;
    in
    if merged == [ ] then
      builtins.throw ''
        agent-sandbox: detected shell.nix at ${shellPath}, but it did not expose any
        packages via buildInputs/nativeBuildInputs/packages.

        Add nix/packages.nix for explicit package contract:
          { pkgs, unstable }: [ pkgs.bun pkgs.git ]
      ''
    else
      merged;
in
if packagesPath != null then
  fromPackages
else if shellPath != null then
  fromShell
else
  # The default placeholder input intentionally has no package files so
  # flake introspection commands (flake show/metadata) still evaluate.
  [ ]
