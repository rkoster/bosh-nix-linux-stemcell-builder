{
  description = "Nix POC: Ubuntu Noble BOSH stemcell (milestones M0-M1)";

  # Upstream nixpkgs stable release. Replaces the unmaintained
  # github:lheckemann/nixpkgs#foreign-distros fork: nixos-26.05 ships the same
  # vmTools deb-image machinery (runInLinuxVM, createEmptyImage,
  # debClosureGenerator, defaultCreateRootFS) the POC relies on. The one thing
  # upstream still gets wrong for usrmerged Ubuntu (raw dpkg-deb extract) is
  # fixed locally in poc/lib/fill-disk-usrmerge.nix.
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
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
