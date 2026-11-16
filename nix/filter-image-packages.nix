{ lib }:
packages:
let
  # Runtime tools have one canonical copy in the image. Project packages may
  # come from another nixpkgs pin and still reference their own store versions.
  isShadowedImagePackage =
    pkg:
    let
      pname = if pkg ? pname then pkg.pname else "";
      name = if pkg ? name then pkg.name else "";
    in
    pname == "git"
    || lib.hasPrefix "git-" name
    || pname == "bun"
    || lib.hasPrefix "bun-" name
    || pname == "nix"
    || builtins.match "^nix-[0-9].*" name != null
    || pname == "podman"
    || builtins.match "^podman-[0-9].*" name != null
    || pname == "docker"
    || pname == "docker-client"
    || builtins.match "^docker(-client)?-[0-9].*" name != null
    || pname == "procps"
    || lib.hasPrefix "procps-" name
    || pname == "coreutils"
    || pname == "coreutils-full"
    || builtins.match "^coreutils(-full)?-[0-9].*" name != null;
in
builtins.filter (pkg: !(isShadowedImagePackage pkg)) packages
