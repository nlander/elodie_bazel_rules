{
  description = "Flake para herramientas de Haskell";
  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
    streamly-env.url = "github:nlander/streamly-env";
  };
  outputs = {self, nixpkgs, flake-utils, streamly-env}:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = nixpkgs.legacyPackages.${system};
        haskellEnv = streamly-env.packages.${system}.default;
      in
      {
        devShells.default = pkgs.mkShell {
          buildInputs = [
            pkgs.bazel_9
          ];
          shellHook = ''
            exec fish
          '';
        };
        packages = {
          ghc-env = haskellEnv;
          xlsx2csv = pkgs.xlsx2csv;
        };
      }
    );
}
