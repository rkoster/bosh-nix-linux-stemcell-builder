{
  description = "Nix POC: Ubuntu Noble BOSH stemcell (milestones M0-M1)";

  # Inputs match lheckemann/nixbuntu-samples exactly; poc/flake.lock pins the
  # revisions verbatim so evaluation is reproducible without ref resolution.
  inputs = {
    nixpkgs.url = "github:lheckemann/nixpkgs/foreign-distros";
    flake-parts.url = "github:hercules-ci/flake-parts";
  };

  outputs = inputs: inputs.flake-parts.lib.mkFlake { inherit inputs; } ({ lib, ... }: {
    systems = [ "x86_64-linux" ];
    perSystem = { pkgs, ... }: {
      # One package per file in ./examples (mirrors the samples repo layout).
      packages = lib.mapAttrs' (name: _type: {
        name = lib.replaceStrings [ ".nix" ] [ "" ] name;
        value = pkgs.callPackage ./examples/${name} { };
      }) (builtins.readDir ./examples);

      devShells.default = pkgs.mkShell {
        # nix-prefetch-url ships with Nix itself, so no extra package needed.
        packages = with pkgs; [ qemu OVMF xz ];
        shellHook = ''
          export OVMF_FD="${pkgs.OVMF.fd}/FV/OVMF.fd"
          echo "POC devshell: OVMF_FD=$OVMF_FD"
        '';
      };
    };
  });
}
