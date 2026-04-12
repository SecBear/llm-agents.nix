{
  lib,
  stdenv,
  fetchFromGitHub,
  bun2nix,
  bun,
  rustc,
  cargo,
  rustPlatform,
  pkg-config,
  makeWrapper,
  autoPatchelfHook,
  zlib,
  libclang,
  zig,
  rcodesign,
}:

let
  versionData = builtins.fromJSON (builtins.readFile ./hashes.json);
  inherit (versionData) version hash cargoHash;

  src = fetchFromGitHub {
    owner = "can1357";
    repo = "oh-my-pi";
    tag = "v${version}";
    inherit hash;
  };

  platformTag =
    if stdenv.hostPlatform.isDarwin && stdenv.hostPlatform.isx86_64 then
      "darwin-x64"
    else if stdenv.hostPlatform.isDarwin && stdenv.hostPlatform.isAarch64 then
      "darwin-arm64"
    else if stdenv.hostPlatform.isLinux && stdenv.hostPlatform.isx86_64 then
      "linux-x64"
    else if stdenv.hostPlatform.isLinux && stdenv.hostPlatform.isAarch64 then
      "linux-arm64"
    else
      throw "Unsupported platform for omp: ${stdenv.hostPlatform.system}";

  bunTarget =
    if stdenv.hostPlatform.isDarwin && stdenv.hostPlatform.isx86_64 then
      "bun-darwin-x64"
    else if stdenv.hostPlatform.isDarwin && stdenv.hostPlatform.isAarch64 then
      "bun-darwin-arm64"
    else if stdenv.hostPlatform.isLinux && stdenv.hostPlatform.isx86_64 then
      "bun-linux-x64-modern"
    else if stdenv.hostPlatform.isLinux && stdenv.hostPlatform.isAarch64 then
      "bun-linux-arm64"
    else
      throw "Unsupported platform for omp: ${stdenv.hostPlatform.system}";
in
stdenv.mkDerivation {
  pname = "omp";
  inherit version src;

  cargoDeps = rustPlatform.fetchCargoVendor {
    name = "omp-${version}-cargo-vendor";
    inherit src;
    hash = cargoHash;
  };

  nativeBuildInputs = [
    bun2nix.hook
    bun
    rustc
    cargo
    rustPlatform.cargoSetupHook
    pkg-config
    makeWrapper
    zig
  ]
  ++ lib.optionals stdenv.hostPlatform.isLinux [ autoPatchelfHook ]
  ++ lib.optionals stdenv.hostPlatform.isDarwin [ rcodesign ];

  buildInputs = lib.optionals stdenv.hostPlatform.isLinux [
    stdenv.cc.cc.lib
    zlib
  ];

  # smallvec's `specialization` feature requires nightly Rust.
  # RUSTC_BOOTSTRAP=1 enables nightly features on stable rustc.
  env.RUSTC_BOOTSTRAP = 1;
  env.RUSTFLAGS = lib.optionalString stdenv.hostPlatform.isLinux (
    lib.concatStringsSep " " [
      "-Clink-arg=-Wl,-u,tree_sitter_glimmer_external_scanner_create"
      "-Clink-arg=-Wl,-u,tree_sitter_glimmer_external_scanner_destroy"
      "-Clink-arg=-Wl,-u,tree_sitter_glimmer_external_scanner_reset"
      "-Clink-arg=-Wl,-u,tree_sitter_glimmer_external_scanner_scan"
      "-Clink-arg=-Wl,-u,tree_sitter_glimmer_external_scanner_serialize"
      "-Clink-arg=-Wl,-u,tree_sitter_glimmer_external_scanner_deserialize"
    ]
  );

  bunDeps = bun2nix.fetchBunDeps {
    bunNix = ./bun.nix;
  };

  # We handle build and install ourselves.
  dontUseBunBuild = true;
  dontUseBunInstall = true;
  dontRunLifecycleScripts = true;

  # bun compile embeds JS in the binary; stripping would break it.
  dontStrip = true;

  postPatch = ''
    # bun resolves caret-range specifiers via the npm registry even when the
    # pinned version is already in the local cache. In the Nix sandbox this
    # fails because the network is blocked. Strip ^ and ~ prefixes so bun
    # treats them as exact.
    for f in package.json packages/*/package.json; do
      if [ -f "$f" ]; then
        sed -i 's/: "\^/: "/g; s/: "~/: "/g' "$f"
      fi
    done
    sed -i 's/: "\^/: "/g; s/: "~/: "/g' bun.lock

    # swarm-extension declares a peerDependency on @oh-my-pi/pi-coding-agent
    # with a hard-coded major (e.g. ^13) that upstream forgot to bump for the
    # v14 release. With the workspace package now at 14.x bun cannot satisfy
    # the constraint locally and falls back to the npm registry, which is
    # unreachable in the sandbox. Rewrite it to the workspace reference.
    sed -i 's|"@oh-my-pi/pi-coding-agent": "[0-9][^"]*"|"@oh-my-pi/pi-coding-agent": "workspace:*"|' \
      packages/swarm-extension/package.json bun.lock

    # Reset the stats embedded client bundle to the placeholder so we don't
    # need to build the full React dashboard.
    cat > packages/stats/src/embedded-client.generated.txt <<'PLACEHOLDER'
    export const EMBEDDED_CLIENT_ARCHIVE_TAR_GZ_BASE64 = "";
    PLACEHOLDER
  '';

  buildPhase = ''
    runHook preBuild

    # Native node modules like @napi-rs/cli need libstdc++ at build time.
    ${lib.optionalString stdenv.hostPlatform.isLinux ''
      export LD_LIBRARY_PATH="${lib.makeLibraryPath [ stdenv.cc.cc.lib ]}"
    ''}

    # bindgen (used by zlob crate) needs libclang.
    export LIBCLANG_PATH="${libclang.lib}/lib"
    export TARGET_PLATFORM="${if stdenv.hostPlatform.isDarwin then "darwin" else "linux"}"
    export TARGET_ARCH="${if stdenv.hostPlatform.isAarch64 then "arm64" else "x64"}"

    echo "Building native addon(s)..."
    bun packages/natives/scripts/build-native.ts

    echo "Embedding native addon manifest..."
    bun packages/natives/scripts/embed-native.ts

    echo "Generating docs index..."
    bun packages/coding-agent/scripts/generate-docs-index.ts

    echo "Compiling standalone binary..."
    bun build --compile \
      --define PI_COMPILED=true \
      --external mupdf \
      --target="${bunTarget}" \
      --root . \
      ./packages/coding-agent/src/cli.ts \
      --outfile dist/omp

    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall

    mkdir -p $out/lib/omp $out/bin
    cp dist/omp $out/lib/omp/omp
    cp packages/natives/native/pi_natives.${platformTag}*.node $out/lib/omp/

    ${lib.optionalString stdenv.hostPlatform.isDarwin ''
      for native in $out/lib/omp/*.node; do
        ${lib.getExe rcodesign} sign --code-signature-flags linker-signed "$native"
      done
      ${lib.getExe rcodesign} sign --code-signature-flags linker-signed $out/lib/omp/omp
    ''}

    makeWrapper $out/lib/omp/omp $out/bin/omp \
      --set PI_SKIP_VERSION_CHECK 1 \
    ${lib.optionalString stdenv.hostPlatform.isLinux "--prefix LD_LIBRARY_PATH : ${
      lib.makeLibraryPath [
        zlib
        stdenv.cc.cc.lib
      ]
    }"}

    runHook postInstall
  '';

  passthru.category = "AI Coding Agents";

  meta = with lib; {
    description = "A terminal-based coding agent with multi-model support";
    homepage = "https://github.com/can1357/oh-my-pi";
    changelog = "https://github.com/can1357/oh-my-pi/releases/tag/v${version}";
    license = licenses.mit;
    sourceProvenance = with sourceTypes; [ fromSource ];
    maintainers = with maintainers; [ aldoborrero ];
    mainProgram = "omp";
    platforms = [
      "x86_64-linux"
      "aarch64-linux"
      "x86_64-darwin"
      "aarch64-darwin"
    ];
  };
}
