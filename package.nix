{ lib
, stdenv
, fetchurl
, makeWrapper
, patchelf
, vulkan-loader
, vulkan-tools
}:

let
  version = "0.78.1";
in
stdenv.mkDerivation {
  pname = "mesh-llm";
  inherit version;

  src = fetchurl {
    url = "https://github.com/Mesh-LLM/mesh-llm/releases/download/v${version}/mesh-llm-v${version}-x86_64-unknown-linux-gnu-vulkan.tar.gz";
    hash = "sha256-NUvkMjlTVRJRvk+yHStsLisVjXlZZRsrJ7oaN1nJOaI=";
  };

  sourceRoot = "mesh-bundle";

  nativeBuildInputs = [
    makeWrapper
    patchelf
  ];

  dontBuild = true;
  dontConfigure = true;
  # mesh-llm checks the runtime libraries against sha256 sums in their manifest,
  # so only the host binary's interpreter is patched.
  dontFixup = true;

  installPhase = ''
    runHook preInstall
    mkdir -p "$out/libexec/mesh-llm" "$out/bin"
    cp -a . "$out/libexec/mesh-llm/"
    patchelf --set-interpreter "$(cat ${stdenv.cc}/nix-support/dynamic-linker)" \
      "$out/libexec/mesh-llm/mesh-llm"
    # The runtime libraries carry RUNPATH=$ORIGIN, which makes glibc ignore the
    # host binary's RPATH when resolving their libvulkan and libstdc++ imports.
    makeWrapper "$out/libexec/mesh-llm/mesh-llm" "$out/bin/mesh-llm" \
      --prefix LD_LIBRARY_PATH : ${lib.makeLibraryPath [ vulkan-loader stdenv.cc.cc.lib ]} \
      --prefix PATH : ${lib.makeBinPath [ vulkan-tools ]} \
      --set MESH_LLM_NATIVE_RUNTIME_BUNDLE_DIR "$out/libexec/mesh-llm/native-runtimes"
    runHook postInstall
  '';

  passthru.runtimeId = "meshllm-native-runtime-linux-x86_64-vulkan";

  meta = {
    description = "Pool GPUs over the internet for LLM inference (Vulkan build)";
    homepage = "https://github.com/Mesh-LLM/mesh-llm";
    license = lib.licenses.asl20;
    sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
    platforms = [ "x86_64-linux" ];
    mainProgram = "mesh-llm";
  };
}
