{
  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
    flake-parts.follows = "baskingspot/flake-parts";
    baskingspot = {
      url = "github:baskingspot/nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    inputs@{ flake-parts, ... }:
    flake-parts.lib.mkFlake { inherit inputs; } {
      # imports and inputsFrom below mirror each other, including the
      # toolchain version. Both versions build; the default is the current
      # stable, and `zig-old` is the previous one for the CI compatibility
      # lane and for local checks.
      imports = with inputs.baskingspot.flakeModules; [
        base
        docs
        zig."0.16"
        zig."0.17"
      ];

      perSystem =
        { pkgs, config, ... }:
        let
          project = with pkgs; [ goperf ];
        in
        {
          devShells.default = pkgs.mkShell {
            inputsFrom = [
              config.devShells.base
              config.devShells.docs
              config.devShells."zig-0-17"
            ];
            packages = project;
          };

          devShells.zig-old = pkgs.mkShell {
            inputsFrom = [
              config.devShells.base
              config.devShells.docs
              config.devShells."zig-0-16"
            ];
            packages = project;
          };
        };
    };
}
