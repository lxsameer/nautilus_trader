{
  description = "Dev shell for building nautilus_trader from source";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
    rust-overlay = {
      url = "github:oxalica/rust-overlay";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, flake-utils, rust-overlay }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = import nixpkgs {
          inherit system;
          overlays = [ rust-overlay.overlays.default ];
        };

        # Match the exact toolchain pinned in rust-toolchain.toml so local
        # builds use the same compiler as CI.
        rustToolchain =
          (pkgs.rust-bin.fromRustupToolchainFile ./rust-toolchain.toml).override {
            extensions = [ "rust-src" "clippy" "rustfmt" ];
          };
      in
      {
        devShells.default = pkgs.mkShell {
          packages = [
            rustToolchain
            pkgs.cargo-nextest
            pkgs.cargo-binstall

            pkgs.python312
            pkgs.uv

            pkgs.clang
            pkgs.llvmPackages.libclang
            # The Linux rustflags in .cargo/config.toml select the lld
            # linker (-fuse-ld=lld); without it Linux builds fail to link.
            pkgs.lld
            pkgs.pkg-config
            pkgs.openssl

            pkgs.capnproto

            pkgs.gnumake
            pkgs.git
          ];

          # Needed by bindgen / PyO3 build scripts that shell out to clang.
          LIBCLANG_PATH = "${pkgs.llvmPackages.libclang.lib}/lib";

          shellHook = ''
            echo "nautilus_trader dev shell"
            echo "rustc: $(rustc --version)"
            echo "uv:    $(uv --version)"
            echo "capnp: $(capnp --version 2>/dev/null || echo 'not found')"
            echo

            # .nautilus-engineering/tools.toml and python/pyproject.toml are
            # the project's source of truth for pinned tool versions; warn
            # (rather than fail) if nixpkgs drifts from them.
            _capnp_required="$(sed -n '/^\[capnp\]/,/^\[/{s/^version = "\(.*\)"/\1/p}' .nautilus-engineering/tools.toml 2>/dev/null)"
            _capnp_actual="$(capnp --version 2>/dev/null | awk '{print $NF}')"
            if [ -n "$_capnp_required" ] && [ "$_capnp_actual" != "$_capnp_required" ]; then
              echo "warning: capnp $_capnp_actual from nixpkgs != pinned $_capnp_required" \
                   "(run ./scripts/install-capnp.sh if serialization schema compilation fails)"
            fi

            _uv_required_minor="$(sed -n 's/^required-version = ">=\([0-9]*\.[0-9]*\).*/\1/p' python/pyproject.toml 2>/dev/null)"
            _uv_actual="$(uv --version 2>/dev/null | awk '{print $2}')"
            if [ -n "$_uv_required_minor" ] && [ -n "$_uv_actual" ]; then
              case "$_uv_actual" in
                "$_uv_required_minor".*) ;;
                *) echo "warning: uv $_uv_actual from nixpkgs is outside the required-version range in python/pyproject.toml (>=$_uv_required_minor)" ;;
              esac
            fi
            unset _capnp_required _capnp_actual _uv_required_minor _uv_actual

            echo "First time in a fresh checkout:"
            echo "  uv sync --all-extras   # or: make sync"
            echo "  make build-debug       # debug build (or: make build for release)"
            echo

            # Required for Rust/PyO3 once python/.venv exists (see
            # docs/developer_guide/environment_setup.md, step 4). Rerun
            # this shellHook (re-enter the shell) after the first sync.
            if [ -x python/.venv/bin/python ]; then
              export PYO3_PYTHON="$PWD/python/.venv/bin/python"
              if [ "$(uname -s)" = "Linux" ]; then
                _python_lib_dir="$("$PYO3_PYTHON" -c 'import sysconfig; print(sysconfig.get_config_var("LIBDIR"))')"
                export LD_LIBRARY_PATH="$_python_lib_dir''${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
                unset _python_lib_dir
              fi
              export PYTHONHOME="$("$PYO3_PYTHON" -c 'import sys; print(sys.base_prefix)')"
              echo "PYO3_PYTHON: $PYO3_PYTHON"
            else
              echo "No python/.venv yet — run 'make sync' first, then re-enter this shell" \
                   "so PYO3_PYTHON/PYTHONHOME get set."
            fi
          '';
        };
      });
}
