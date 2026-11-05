# `programs.soundcraft` for NixOS and home-manager.
#
# The option set is shared; `kind` selects only the behaviour the target module system can express:
# home-manager writes the settings overlay and the palette variable per user, NixOS installs the
# package and the MIME default for the whole system. NixOS cannot write per-user files, so it never
# writes `settings` and it does not set the palette variable.
#
# The overlay is `settings.override.json` beside `ui.json` (`apps/soundcraft/src/config.rs`), merged
# over the saved preferences at start-up. SoundCraft never writes it, so the declarative values
# survive a normal save.
{ kind }:
{
  config,
  lib,
  pkgs,
  # The package of this flake; `flake.nix` passes it through `_module.args`, so importing the
  # module directly needs no overlay.
  soundcraftPackage ? pkgs.soundcraft,
  # `flake.nix` passes the source build and the pre-built release binary separately. Importing the
  # module directly falls back to `soundcraftPackage` and no binary.
  soundcraftSourcePackage ? soundcraftPackage,
  soundcraftBinaryPackage ? null,
  ...
}:

let
  inherit (lib)
    mkEnableOption
    mkIf
    mkOption
    types
    ;

  cfg = config.programs.soundcraft;

  jsonFormat = pkgs.formats.json { };

  # The same list as `packaging/linux/ai.storyteller.soundcraft.desktop` (`MimeType=`).
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

  desktopFile = "ai.storyteller.soundcraft.desktop";

  # The per-user settings directory: `$XDG_CONFIG_HOME/soundcraft` on Linux.
  settingsDir = "${config.xdg.configHome}/soundcraft";

  associations = lib.genAttrs mimeTypes (_: [ desktopFile ]);
in
{
  options.programs.soundcraft = {
    enable = mkEnableOption "SoundCraft";

    useBinary = mkOption {
      type = types.bool;
      default = true;
      description = ''
        Install the pre-built Linux binary from `binary-url.json` when this system has one,
        instead of building from source. Falls back to the source build when the file is missing
        or the system is unsupported.
      '';
    };

    package = mkOption {
      type = types.package;
      default =
        if cfg.useBinary && soundcraftBinaryPackage != null then
          soundcraftBinaryPackage
        else
          soundcraftSourcePackage;
      defaultText = lib.literalMD "the pre-built binary from `binary-url.json`, or the source build";
      description = "The SoundCraft package to install.";
    };

    setAsDefault = mkOption {
      type = types.bool;
      default = false;
      description = ''
        Open SoundCraft sessions and audio files with SoundCraft by default (the MIME types of
        `packaging/linux/ai.storyteller.soundcraft.desktop`).
      '';
    };

    settings = mkOption {
      type = jsonFormat.type;
      default = { };
      description = ''
        Free-form preferences merged over the app's settings. Home-manager writes them to
        `settings.override.json`; NixOS ignores them, because it cannot write per-user files.
      '';
    };

    paletteFile = mkOption {
      type = types.nullOr types.path;
      default = null;
      description = ''
        Optional shared palette file, exported as `CRAFT_PALETTE_FILE`. Inert until theming support
        lands.
      '';
    };
  };

  config = lib.mkMerge [
    (mkIf cfg.enable (
      if kind == "nixos" then
        {
          environment.systemPackages = [ cfg.package ];
          xdg.mime.defaultApplications = mkIf cfg.setAsDefault associations;
        }
      else
        {
          home.packages = [ cfg.package ];
          home.sessionVariables = mkIf (cfg.paletteFile != null) {
            CRAFT_PALETTE_FILE = toString cfg.paletteFile;
          };
          home.file."${settingsDir}/settings.override.json" = mkIf (cfg.settings != { }) {
            source = jsonFormat.generate "soundcraft-settings.override.json" cfg.settings;
          };
          xdg.mimeApps = mkIf cfg.setAsDefault {
            enable = true;
            defaultApplications = associations;
            # Associated even when another application stays the default.
            associations.added = associations;
          };
        }
    ))
  ];
}
