{
  description = "PR preview environments — GitHub Action + NixOS module";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.11";

    extra-container = {
      url = "github:erikarvstedt/extra-container";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      extra-container,
    }:
    let
      previewModule =
        { ... }:
        {
          imports = [ ./nixos/module.nix ];
          config._module.args.extraContainer = extra-container;
        };
    in
    {
      nixosModules.default = previewModule;
      nixosModules.preview = previewModule;
    };
}
