{
  description = "nimpkgs crawler";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
  };

  outputs = {
    self,
    nixpkgs,
  }: let
    inherit (nixpkgs.lib) genAttrs;
    forAllSystems = f:
      genAttrs ["x86_64-linux" "x86_64-darwin" "aarch64-linux" "aarch64-darwin"]
      (system:
        f (import nixpkgs {
          localSystem.system = system;
        }));
  in {
    devShells = forAllSystems (pkgs: {
      default = pkgs.mkShell {
        buildInputs = with pkgs; [nim nim-atlas openssl];
      };
    });
  };
}
