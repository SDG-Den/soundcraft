{
  description = "SoundCraft — a digital audio workstation, in pure Rust";

  inputs = {
    # SoundCraft needs edition 2024 and rustc ≥ 1.95, so the flake tracks unstable. Consumers on a
    # release channel can retarget it: `inputs.soundcraft.inputs.nixpkgs.follows = "nixpkgs";`
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    # Splits the dependency build from the app build, so a source change does not recompile the
    # whole dependency graph.
    crane = {
      url = "github:ipetkov/crane";
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      crane,
    }:
    let
      inherit (nixpkgs) lib;

      # No x86_64-darwin: the pinned nixpkgs dropped it. On an Intel Mac, retarget nixpkgs at a
      # release that still has it, or install the release build.
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "aarch64-darwin"
      ];

      # The AppStream metadata carries a release date. The flake source's own commit date is
      # reproducible, unlike "now"; a tarball or dirty tree without one falls back to the epoch.
      buildDate =
        let
          d = self.lastModifiedDate or "";
        in
        if builtins.stringLength d >= 8 then
          "${builtins.substring 0 4 d}-${builtins.substring 4 2 d}-${builtins.substring 6 2 d}"
        else
          "1970-01-01";

      packageArgs = {
        inherit buildDate;
      };

      # Written by `.github/workflows/binary.yml`; absent until the first binary release.
      binaryInfo =
        if builtins.pathExists ./binary-url.json then
          builtins.fromJSON (builtins.readFile ./binary-url.json)
        else
          null;

      forAllSystems = f: lib.genAttrs systems (system: f (import nixpkgs { inherit system; }) system);
    in
    {
      packages = forAllSystems (
        pkgs: system:
        let
          source = pkgs.callPackage ./nix/package.nix (packageArgs // { craneLib = crane.mkLib pkgs; });
          binary = pkgs.callPackage ./nix/binary.nix {
            name = "soundcraft";
            info = binaryInfo;
          };
          binaryAvailable = binaryInfo != null && binaryInfo.system == system;
        in
        {
          soundcraft-source = source;
          soundcraft = if binaryAvailable then binary else source;
          default = if binaryAvailable then binary else source;
        }
        // lib.optionalAttrs binaryAvailable {
          soundcraft-binary = binary;
        }
      );

      # `nixpkgs.overlays = [ inputs.soundcraft.overlays.default ]` → `pkgs.soundcraft` everywhere.
      overlays.default = final: _prev: {
        soundcraft = final.callPackage ./nix/package.nix (packageArgs // { craneLib = crane.mkLib final; });
      };

      apps = forAllSystems (
        _: system: {
          default = {
            type = "app";
            program = lib.getExe self.packages.${system}.soundcraft;
          };
        }
      );

      devShells = forAllSystems (
        pkgs: system:
        let
          soundcraft = self.packages.${system}.soundcraft-source;
        in
        {
          default = pkgs.mkShell {
            # The package's own native inputs, so `cargo run` in the shell needs no extra setup.
            inputsFrom = [ soundcraft ];
            packages = with pkgs; [
              cargo
              rustc
              clippy
              rustfmt
              rust-analyzer
            ];
            # `cargo run` dlopens the Vulkan loader, libwayland, libxkbcommon and ALSA like the
            # packaged binary.
            LD_LIBRARY_PATH = lib.makeLibraryPath soundcraft.passthru.runtimeLibs;
            RUST_BACKTRACE = "1";
          };
        }
      );

      checks = forAllSystems (
        pkgs: system:
        let
          soundcraft = self.packages.${system}.soundcraft-source;
        in
        {
          soundcraft = soundcraft;

          # Both module entry points evaluate with `enable = true` (no full NixOS evaluation).
          modules = pkgs.callPackage ./nix/module-check.nix { inherit soundcraft; };

          # `nix fmt` formats the flake; this keeps it formatted.
          formatting = pkgs.runCommand "soundcraft-nix-formatting" { nativeBuildInputs = [ pkgs.nixfmt ]; } ''
            nixfmt --check ${./flake.nix} ${./nix}
            touch $out
          '';
        }
      );

      formatter = forAllSystems (pkgs: _: pkgs.nixfmt);

      # Both modules take the package from this flake unless `programs.soundcraft.package` is set,
      # so `nixosModules.default`/`homeManagerModules.default` work without the overlay.
      nixosModules.default =
        { pkgs, ... }:
        let
          system = pkgs.stdenv.hostPlatform.system;
        in
        {
          imports = [ (import ./nix/module.nix { kind = "nixos"; }) ];
          _module.args = {
            soundcraftSourcePackage = self.packages.${system}.soundcraft-source;
            soundcraftBinaryPackage = self.packages.${system}.soundcraft-binary or null;
          };
        };

      homeManagerModules.default =
        { pkgs, ... }:
        let
          system = pkgs.stdenv.hostPlatform.system;
        in
        {
          imports = [ (import ./nix/module.nix { kind = "home-manager"; }) ];
          _module.args = {
            soundcraftSourcePackage = self.packages.${system}.soundcraft-source;
            soundcraftBinaryPackage = self.packages.${system}.soundcraft-binary or null;
          };
        };
    };
}
