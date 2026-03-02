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

  fromShell =
    let
      shellExpr = import shellPath;
      shellDrv =
        if builtins.isFunction shellExpr then shellExpr { inherit pkgs; } else shellExpr;
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
