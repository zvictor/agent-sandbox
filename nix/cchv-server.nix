{
  lib,
  stdenv,
  fetchurl,
  autoPatchelfHook,
  makeWrapper,
  cairo,
  dbus,
  gdk-pixbuf,
  glib,
  gtk3,
  libsoup_3,
  webkitgtk_4_1,
}:

let
  version = "1.16.0";
  platform = {
    x86_64-linux = {
      artifact = "linux-x64";
      hash = "sha256-73YZQN4s8q4NAQHeOJwxpmcsrJqaLxYap1l5YUTNGOY=";
    };
    aarch64-linux = {
      artifact = "linux-arm64";
      hash = "sha256-OIIcCCNR35GyAnJ1nh6FbBtZSNsop7I6ZNF4hvabH8U=";
    };
  }.${stdenv.hostPlatform.system} or (throw "cchv-server is only packaged for Linux");
in
stdenv.mkDerivation {
  pname = "cchv-server";
  inherit version;

  src = fetchurl {
    url = "https://github.com/jhlee0409/claude-code-history-viewer/releases/download/v${version}/cchv-server-${platform.artifact}.tar.gz";
    inherit (platform) hash;
  };
  sourceRoot = ".";

  nativeBuildInputs = [
    autoPatchelfHook
    makeWrapper
  ];

  buildInputs = [
    cairo
    dbus
    gdk-pixbuf
    glib
    gtk3
    libsoup_3
    stdenv.cc.cc.lib
    webkitgtk_4_1
  ];

  dontConfigure = true;
  dontBuild = true;

  installPhase = ''
    runHook preInstall
    install -Dm0755 cchv-server "$out/bin/cchv-server"
    wrapProgram "$out/bin/cchv-server" \
      --set-default GDK_BACKEND x11
    runHook postInstall
  '';

  meta = {
    description = "Headless WebUI server for Claude Code History Viewer";
    homepage = "https://github.com/jhlee0409/claude-code-history-viewer";
    license = lib.licenses.mit;
    platforms = [
      "x86_64-linux"
      "aarch64-linux"
    ];
    mainProgram = "cchv-server";
  };
}
