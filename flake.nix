{
  description = "PR preview environments — GitHub Action + NixOS module";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.11";

  outputs =
    { self, nixpkgs }:
    {
      nixosModules.default = import ./nixos/module.nix;
      nixosModules.preview = import ./nixos/module.nix;
    };
}
