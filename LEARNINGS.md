# LEARNINGS

- **nixpkgs `openblas` is ILP64 (blas64=true) on x86_64-linux but LP64 on
  aarch64-darwin** (verified on rev a799d3e3, 2026-06-10). Rust's
  `ndarray-linalg` system bindings expect the standard LP64 LAPACK ABI, so
  linking plain `openblas` works on a Mac and explodes on Linux with
  "On entry to DGETRF parameter number 4 had an illegal value" (integer
  args read at the wrong width). Use `pkgs.openblasCompat` (forced LP64)
  for anything binding BLAS/LAPACK from Rust/C. A macOS-only green build
  proves nothing here — only the Linux CI run surfaced it.
- **Garnix build logs are fetchable**: `https://app.garnix.io/api/build/<id>/logs`
  (JSON; `<id>` from the check-run's details_url). The badge endpoint's
  "N builds succeeded out of M" message is ambiguous mid-run — poll the
  GitHub check-run "All Garnix checks" conclusion instead.
- **Hermetic ML functional tests in the Nix sandbox**: pin model files as
  `fetchurl` fixed-output derivations + `linkFarm` them into a models dir.
  Network only in hash-verified FODs; CI then runs real inference purely.
