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
            buildInputs = with pkgs; [ openblasCompat ]
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

          # CPU-mode model files, pinned as fixed-output derivations so the
          # functional check runs REAL diarization inside the pure sandbox —
          # network only ever happens in hash-verified FODs.
          modelFiles = {
            "segmentation-3.0.onnx" = "sha256-A4uXF0HtYjr5dz7K/e+kt7xSNSAJnCpo+FaLJBieitk=";
            "wespeaker-voxceleb-resnet34.onnx" = "sha256-IDpMZxEhZ1gKsfy2L0VoxjNJn7KDgFiQrr4cSFZPzA8=";
            "wespeaker-voxceleb-resnet34.onnx.data" = "sha256-3BBeeFcVZhE4G5XMlhsnfY4eCY568ckZp3xoxyV86VY=";
            "wespeaker-voxceleb-resnet34.min_num_samples.txt" = "sha256-5N+JHEhNeruYXa31OfoYg6ZG2rYzevXK5BWcWHtwUMw=";
            "plda_lda.npy" = "sha256-4gybASvr0aq9paOKEn5jpDzzXevcUCcV/BQ+L7a8PEs=";
            "plda_tr.npy" = "sha256-5wC2jLMZ3j+vtfoJPrkiLCPERwhHQfjTpTNkDUJVEO4=";
            "plda_mu.npy" = "sha256-0obUis+Zu8HtFQL+0KPjYa5WJs4YcMi+n3OXxeR4hsY=";
            "plda_psi.npy" = "sha256-1xKMntLyipeBlxgFExEp8HfAT5SOLfEuUtzbmfK05fU=";
            "plda_phi.npy" = "sha256-H0A62klppYl7JJEuXCW4HtRGs6UTqQE1vvPFyIWZJnc=";
            "plda_mean1.npy" = "sha256-5CTAw1IYKqjg9VXewfOzDimiC57Wsl0znxEq+S5R428=";
            "plda_mean2.npy" = "sha256-b2+3CKIDcZe1uE/+qo8UDLh4CI++zWqwQq0mp2kb0s8=";
          };
          speakrsModels = pkgs.linkFarm "speakrs-models" (pkgs.lib.mapAttrsToList
            (name: hash: {
              inherit name;
              path = pkgs.fetchurl {
                url = "https://huggingface.co/avencera/speakrs-models/resolve/main/${name}";
                inherit hash;
              };
            })
            modelFiles);
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
          # Real diarization on the committed two-speaker fixture, cpu mode,
          # hermetic: models from pinned FODs, ORT via the CLI wrapper default.
          functional-test = pkgs.runCommand "speakrs-ffi-functional-test"
            { nativeBuildInputs = [ pkgs.bash pkgs.ffmpeg pkgs.python3 pkg ]; } ''
            export SPEAKRS_DIARIZE_BIN=${pkg}/bin/speakrs-diarize
            export SPEAKRS_FFI_MODELS_DIR=${speakrsModels}
            export SPEAKRS_FFI_FIXTURE=${./tests/fixtures/two_speakers_16k.wav}
            export TMPDIR=$(mktemp -d)
            bash ${./tests/cli/test_functional.bash}
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
              openblasCompat
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
