{
  description = "speakrs_ffi — C FFI for the speakrs speaker-diarization library (PCM in, JSON out)";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs = { self, nixpkgs }:
    let
      systems = [ "aarch64-darwin" "x86_64-linux" "aarch64-linux" ];
      forAllSystems = f: nixpkgs.lib.genAttrs systems (system: f system);
    in
    {
      packages = forAllSystems (system:
        let
          pkgs = import nixpkgs { inherit system; };
          isDarwin = pkgs.stdenv.isDarwin;

          # Runtime dlopen target for ort's load-dynamic mode (cpu/cuda paths).
          # CoreML mode on macOS never touches ONNX Runtime.
          ortLib = "${pkgs.onnxruntime}/lib/libonnxruntime${if isDarwin then ".dylib" else ".so"}";
        in
        rec {
          default = pkgs.rustPlatform.buildRustPackage {
            pname = "speakrs_ffi";
            version = "0.1.0";
            src = ./.;

            cargoHash = "sha256-rUWgFFXbp+v2r45XGrduoGvzGFOMqjYS8KStuqnGCD8=";

            nativeBuildInputs = with pkgs; [ pkg-config makeWrapper ];
            buildInputs = with pkgs; [ openblas ]
              ++ pkgs.lib.optionals isDarwin [ apple-sdk ]
              ++ pkgs.lib.optionals (!isDarwin) [ openssl ];

            # Tests are sandbox-safe by design: error paths only, no models,
            # no network. The happy path runs outside the sandbox (./test full).
            doCheck = true;

            postInstall = ''
              # C header
              mkdir -p $out/include
              cp include/speakrs_ffi.h $out/include/

              ${pkgs.lib.optionalString isDarwin ''
                # Give the dylib an absolute install_name so linked consumers
                # (like the CLI below) resolve it without DYLD games.
                ${pkgs.darwin.cctools}/bin/install_name_tool -id \
                  $out/lib/libspeakrs_ffi.dylib $out/lib/libspeakrs_ffi.dylib
              ''}

              # C CLI — dogfoods the FFI header + linkage like any consumer.
              mkdir -p $out/bin
              $CC cli/speakrs_diarize.c \
                -I $out/include -L $out/lib -lspeakrs_ffi \
                ${pkgs.lib.optionalString (!isDarwin) "-Wl,-rpath,$out/lib"} \
                -O2 -o $out/bin/speakrs-diarize

              # Default ORT dylib for cpu mode; respected only if unset by user.
              wrapProgram $out/bin/speakrs-diarize \
                --set-default ORT_DYLIB_PATH ${ortLib}
            '';

            passthru = { inherit ortLib; };

            meta = with pkgs.lib; {
              description = "C FFI for speakrs speaker diarization";
              homepage = "https://github.com/pmarreck/speakrs_ffi";
              license = licenses.asl20;
              platforms = systems;
            };
          };
        });

      checks = forAllSystems (system:
        let
          pkgs = import nixpkgs { inherit system; };
          pkg = self.packages.${system}.default;
        in
        {
          build = pkg;
          # CLI surface tests (bash). Error-path only: no models, no network.
          cli-test = pkgs.runCommand "speakrs-ffi-cli-test"
            { nativeBuildInputs = [ pkgs.bash pkg ]; } ''
            export SPEAKRS_DIARIZE_BIN=${pkg}/bin/speakrs-diarize
            export TMPDIR=$(mktemp -d)
            bash ${./tests/cli/test_cli.bash}
            echo ok > $out
          '';
        });

      devShells = forAllSystems (system:
        let
          pkgs = import nixpkgs { inherit system; };
          isDarwin = pkgs.stdenv.isDarwin;
        in
        {
          default = pkgs.mkShell {
            packages = with pkgs; [
              cargo
              rustc
              clippy
              rustfmt
              pkg-config
              openblas
              onnxruntime
            ] ++ pkgs.lib.optionals isDarwin [ apple-sdk darwin.cctools ]
              ++ pkgs.lib.optionals (!isDarwin) [ openssl ];
            shellHook = ''
              export ORT_DYLIB_PATH="${pkgs.onnxruntime}/lib/libonnxruntime${if isDarwin then ".dylib" else ".so"}"
              echo "speakrs_ffi dev shell — cargo, rustc, openblas, onnxruntime (ORT_DYLIB_PATH set)"
            '';
          };
        });
    };
}
