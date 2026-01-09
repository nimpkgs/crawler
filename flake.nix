{
  description = "nimpkgs crawler";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
    nim2nix = {
      url = "github:daylinmorgan/nim2nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    { nixpkgs, nim2nix, ... }:
    let
      inherit (nixpkgs.lib) genAttrs;
      systems = [
        "x86_64-linux"
        "x86_64-darwin"
        "aarch64-linux"
        "aarch64-darwin"
      ];
      forSystem =
        f: system:
        f (
          import nixpkgs {
            inherit system;
            overlays = [ nim2nix.overlays.default ];
          }
        );
      forAllSystems = f: genAttrs systems (forSystem f);
    in
    {
      devShells = forAllSystems (pkgs: {
        default = pkgs.mkShell {
          buildInputs = with pkgs; [
            nim
            nimble
            openssl
          ];
        };
      });
      packages = forAllSystems (pkgs: {
        default = pkgs.callPackage (
          {
            lib,
            makeWrapper,
            openssl,
            nimble,
            buildNimblePackage,
          }:
          buildNimblePackage {
            pname = "crawler";
            version = "unstable";
            src = ./.;
            buildInputs = [ openssl ];
            nativeBuildInputs = [ makeWrapper ];
            nimbleDepsHash = "sha256-XLLaeTdJlWPQneE79IOTNdMXYkfI+MvBhNBqExDzd0M=";
            postInstall = ''
              wrapProgram $out/bin/crawler \
                --prefix PATH : ${lib.makeBinPath [ nimble ]}
            '';
          }
        ) { };
      });
      formatter = forAllSystems (pkgs: pkgs.nixfmt-rfc-style);
    };
}
