{
  description = "Nix POC: Ubuntu Noble BOSH stemcell (milestones M0-M1)";

  # Upstream nixpkgs stable release. Replaces the unmaintained
  # github:lheckemann/nixpkgs#foreign-distros fork: nixos-26.05 ships the same
  # vmTools deb-image machinery (runInLinuxVM, createEmptyImage,
  # debClosureGenerator, defaultCreateRootFS) the POC relies on. The one thing
  # upstream still gets wrong for usrmerged Ubuntu (raw dpkg-deb extract) is
  # fixed locally in rootfs/fill-disk-usrmerge.nix.
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
    flake-parts.url = "github:hercules-ci/flake-parts";
    treefmt-nix.url = "github:numtide/treefmt-nix";
  };

  outputs =
    inputs:
    inputs.flake-parts.lib.mkFlake { inherit inputs; } (
      { ... }: {
        imports = [ inputs.treefmt-nix.flakeModule ];
        systems = [ "x86_64-linux" ];
        perSystem =
          { pkgs, ... }:
          let
            noble-stemcell-disk = pkgs.callPackage ./build/stemcells/openstack-kvm-disk.nix { };
            noble-stemcell-aws-disk = pkgs.callPackage ./build/stemcells/aws-disk.nix { };
          in
          {
            # Formatter and checks
            treefmt = {
              projectRootFile = "flake.nix";
              programs.nixfmt.enable = true;
              programs.shfmt.enable = true;
              programs.shellcheck.enable = true;
            };

            # Determinism guards: emit the assembled disk sha256 as a stable
            # fingerprint. The genuine same-machine byte-determinism gate is
            # `nix build .#noble-stemcell-disk --rebuild` (+ -aws-disk); see
            # build/checks/disk-determinism.nix for why --rebuild on the check
            # itself is insufficient.
            checks = {
              disk-determinism-openstack = pkgs.callPackage ./build/checks/disk-determinism.nix {
                disk = noble-stemcell-disk;
                diskFile = "root.qcow2";
              };
              disk-determinism-aws = pkgs.callPackage ./build/checks/disk-determinism.nix {
                disk = noble-stemcell-aws-disk;
                diskFile = "root.img";
              };
            };

            # Explicit outputs: os-image / os-image-aws (Phase 1),
            # noble-stemcell + openstack-kvm and noble-stemcell-aws + aws (Phase 2),
            # and source-built components.
            packages =
              let
                blobstoreClis = pkgs.callPackage ./build/pkgs/blobstore-clis.nix { };
                openstack-kvm = pkgs.callPackage ./build/stemcells/openstack-kvm.nix { };
                aws = pkgs.callPackage ./build/stemcells/aws.nix { };
              in
              {
                # PHASE 1: OS image (rootfs tarball)
                os-image = pkgs.callPackage ./build/rootfs/os-image.nix { };
                noble-rootfs = pkgs.callPackage ./build/rootfs/rootfs.nix { };

                # PHASE 2 (OpenStack/KVM)
                noble-stemcell-disk = noble-stemcell-disk;
                noble-stemcell = openstack-kvm;
                openstack-kvm = openstack-kvm;

                # PHASE 2 (AWS / xen, aws-raw heavy stemcell)
                os-image-aws = pkgs.callPackage ./build/rootfs/os-image.nix { infrastructure = "aws"; };
                noble-stemcell-aws-disk = noble-stemcell-aws-disk;
                noble-stemcell-aws = aws;
                aws = aws;

                # Source-built components (names preserved from the old auto-discovery)
                bosh-agent = pkgs.callPackage ./build/pkgs/bosh-agent.nix { };
                monit = pkgs.callPackage ./build/pkgs/monit.nix { };
                bosh-davcli = blobstoreClis.davcli;
                bosh-s3cli = blobstoreClis.s3cli;
                bosh-gcscli = blobstoreClis.gcscli;
                bosh-azure-storage-cli = blobstoreClis.azureStorageCli;
              };

            devShells.default = pkgs.mkShell {
              # nix-prefetch-url ships with Nix itself, so no extra package needed.
              packages = with pkgs; [
                qemu
                OVMF
                xz
              ];
              shellHook = ''
                export OVMF_FD="${pkgs.OVMF.fd}/FV/OVMF.fd"
                echo "POC devshell: OVMF_FD=$OVMF_FD"
              '';
            };

            devShells.repro = pkgs.mkShell {
              packages = with pkgs; [
                diffoscopeMinimal
                xxd
                coreutils
              ];
              shellHook = ''
                echo "Binary reproducibility devshell: diffoscope $(diffoscope --version 2>/dev/null | head -1)"
              '';
            };
          };
      }
    );
}
