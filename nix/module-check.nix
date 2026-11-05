# Evaluates both module entry points with `enable = true` and checks what they configure.
#
# `lib.evalModules` plus stub declarations of the handful of NixOS/home-manager options the module
# touches: a full NixOS evaluation would need the whole nixpkgs module set, and the stubs keep the
# check to the module's own contract. A wrong option type, a missing option, or a behaviour that
# regresses fails evaluation, so `nix flake check` catches it.
{
  lib,
  pkgs,
  soundcraft,
}:

let
  inherit (lib) mkEnableOption mkOption types;

  palette = ../packaging/linux/ai.storyteller.soundcraft.desktop;

  configHome = "/home/test/.config";
  settingsFile = "${configHome}/soundcraft/settings.override.json";

  desktopFile = "ai.storyteller.soundcraft.desktop";

  # Must match `packaging/linux/ai.storyteller.soundcraft.desktop`.
  mimeTypes = [
    "application/x-soundcraft-session"
    "audio/x-wav"
    "audio/wav"
    "audio/vnd.wave"
    "audio/x-aiff"
    "audio/aiff"
    "audio/flac"
    "audio/x-flac"
    "audio/mpeg"
    "audio/midi"
    "audio/x-midi"
  ];

  expected = lib.genAttrs mimeTypes (_: [ desktopFile ]);

  nixosStub = _: {
    options = {
      environment.systemPackages = mkOption {
        type = types.listOf types.package;
        default = [ ];
      };
      xdg.mime.defaultApplications = mkOption {
        type = types.attrsOf (types.listOf types.str);
        default = { };
      };
    };
  };

  homeStub = _: {
    options = {
      home.packages = mkOption {
        type = types.listOf types.package;
        default = [ ];
      };
      home.file = mkOption {
        type = types.attrsOf types.anything;
        default = { };
      };
      home.sessionVariables = mkOption {
        type = types.attrsOf types.str;
        default = { };
      };
      xdg.configHome = mkOption {
        type = types.str;
        default = configHome;
      };
      xdg.mimeApps = mkOption {
        default = { };
        type = types.submodule {
          options = {
            enable = mkEnableOption "mimeApps";
            defaultApplications = mkOption {
              type = types.attrsOf (types.listOf types.str);
              default = { };
            };
            associations.added = mkOption {
              type = types.attrsOf (types.listOf types.str);
              default = { };
            };
          };
        };
      };
    };
  };

  evalModule =
    kind: setAsDefault: settings:
    lib.evalModules {
      specialArgs = { inherit pkgs; };
      modules = [
        (import ./module.nix { inherit kind; })
        (if kind == "nixos" then nixosStub else homeStub)
        {
          programs.soundcraft = {
            enable = true;
            package = soundcraft;
            inherit setAsDefault settings;
            paletteFile = palette;
          };
        }
      ];
    };

  nixos = evalModule "nixos" true { theme = "Light"; };
  nixosPlain = evalModule "nixos" false { };
  home = evalModule "home-manager" true { theme = "Light"; };
  homePlain = evalModule "home-manager" false { };

  assertions = [
    {
      what = "nixos installs the package";
      ok = nixos.config.environment.systemPackages == [ soundcraft ];
    }
    {
      what = "nixos mime defaults";
      ok = nixos.config.xdg.mime.defaultApplications == expected;
    }
    {
      what = "nixos mime defaults without setAsDefault";
      ok = nixosPlain.config.xdg.mime.defaultApplications == { };
    }
    {
      what = "nixos writes no settings";
      ok = !builtins.hasAttr "home" nixosPlain.config;
    }
    {
      what = "home-manager installs the package";
      ok = home.config.home.packages == [ soundcraft ];
    }
    {
      what = "home-manager mime defaults";
      ok = home.config.xdg.mimeApps.defaultApplications == expected;
    }
    {
      what = "home-manager mime associations";
      ok = home.config.xdg.mimeApps.associations.added == expected;
    }
    {
      what = "home-manager palette variable";
      ok = home.config.home.sessionVariables.CRAFT_PALETTE_FILE == toString palette;
    }
    {
      what = "home-manager writes the overlay";
      ok = builtins.hasAttr settingsFile home.config.home.file;
    }
    {
      what = "home-manager writes no overlay for empty settings";
      ok = !builtins.hasAttr settingsFile homePlain.config.home.file;
    }
    {
      what = "home-manager leaves mimeApps alone without setAsDefault";
      ok = homePlain.config.xdg.mimeApps.enable == false;
    }
  ];

  failed = map (a: a.what) (lib.filter (a: !a.ok) assertions);
in
assert lib.assertMsg (failed == [ ]) "soundcraft modules: ${lib.concatStringsSep ", " failed}";
pkgs.runCommand "soundcraft-module-check" { } ''
  grep -q 'theme' ${home.config.home.file.${settingsFile}.source}
  grep -q 'Light' ${home.config.home.file.${settingsFile}.source}
  touch $out
''
