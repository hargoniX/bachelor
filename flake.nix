{
  description = "Bachelor Thesis";

  inputs.typst-lsp.url = "github:nvarner/typst-lsp";
  inputs.typst.follows = "typst-lsp/typst";
  inputs.utils.url = "github:numtide/flake-utils";
  inputs.nixpkgs.url = "github:nixos/nixpkgs/nixpkgs-unstable";
  inputs.pre-commit-hooks.url = "github:cachix/pre-commit-hooks.nix";

  outputs = {
    nixpkgs,
    utils,
    typst,
    typst-lsp,
    pre-commit-hooks,
    ...
  }:
    utils.lib.eachDefaultSystem (system: let
      typst-overlay = _self: _super: {
        typst-lsp = typst-lsp.packages.${system}.default;
        typst = typst.packages.${system}.default.overrideAttrs (_old: {
          dontCheck = true;
        });
      };
      pkgs = nixpkgs.legacyPackages.${system}.appendOverlays [typst-overlay];
      pre-commit-check = pre-commit-hooks.lib.${system}.run {
        src = ./.;
        hooks = {
          alejandra.enable = true;
          deadnix.enable = true;
          statix.enable = true;
        };
      };
      typst-shell = pkgs.mkShell {
        inherit (pre-commit-check) shellHook;
        nativeBuildInputs = [
          pkgs.typst-lsp
          pkgs.typst
        ];
      };
    in {
      devShells.default = typst-shell;
      overlays.default = typst-overlay;
      legacyPackages = pkgs;
      checks.formatting = pre-commit-check;
    });
}
