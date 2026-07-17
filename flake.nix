{
  description = "Nix: Ubuntu Noble + Resolute BOSH stemcell build matrix";

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
            noble-stemcell-rootfs = pkgs.callPackage ./build/stemcells/openstack-kvm-rootfs.nix { };
            noble-stemcell-aws-rootfs = pkgs.callPackage ./build/stemcells/aws-rootfs.nix { };
            noble-stemcell-disk = pkgs.callPackage ./build/stemcells/openstack-kvm-disk.nix { };
            noble-stemcell-aws-disk = pkgs.callPackage ./build/stemcells/aws-disk.nix { };

            resolute-stemcell-rootfs = pkgs.callPackage ./build/stemcells/openstack-kvm-rootfs.nix {
              release = "resolute";
            };
            resolute-stemcell-aws-rootfs = pkgs.callPackage ./build/stemcells/aws-rootfs.nix {
              release = "resolute";
            };
            resolute-stemcell-disk = pkgs.callPackage ./build/stemcells/openstack-kvm-disk.nix {
              release = "resolute";
            };
            resolute-stemcell-aws-disk = pkgs.callPackage ./build/stemcells/aws-disk.nix {
              release = "resolute";
            };
          in
          {
            # Formatter and checks
            treefmt = {
              projectRootFile = "flake.nix";
              programs.nixfmt.enable = true;
              programs.shfmt.enable = true;
              programs.shellcheck.enable = true;
            };

            # Determinism guards: emit built-artifact sha256s as stable
            # fingerprints. The genuine same-machine byte-determinism gate is
            # `nix build <pkg> --rebuild` for BOTH layers (Phase A rootfs AND
            # the disk) -- the disk build reuses the cached rootfs, so RC5/RC7
            # (Phase A) are only re-exercised by rebuilding the rootfs. See
            # build/checks/disk-determinism.nix.
            checks = {
              rootfs-determinism-openstack = pkgs.callPackage ./build/checks/disk-determinism.nix {
                artifact = noble-stemcell-rootfs;
                file = "rootfs-staged.tar.gz";
              };
              rootfs-determinism-aws = pkgs.callPackage ./build/checks/disk-determinism.nix {
                artifact = noble-stemcell-aws-rootfs;
                file = "rootfs-staged.tar.gz";
              };
              disk-determinism-openstack = pkgs.callPackage ./build/checks/disk-determinism.nix {
                artifact = noble-stemcell-disk;
                file = "root.qcow2";
              };
              disk-determinism-aws = pkgs.callPackage ./build/checks/disk-determinism.nix {
                artifact = noble-stemcell-aws-disk;
                file = "root.img";
              };
              rootfs-determinism-resolute-openstack = pkgs.callPackage ./build/checks/disk-determinism.nix {
                artifact = resolute-stemcell-rootfs;
                file = "rootfs-staged.tar.gz";
              };
              rootfs-determinism-resolute-aws = pkgs.callPackage ./build/checks/disk-determinism.nix {
                artifact = resolute-stemcell-aws-rootfs;
                file = "rootfs-staged.tar.gz";
              };
              disk-determinism-resolute-openstack = pkgs.callPackage ./build/checks/disk-determinism.nix {
                artifact = resolute-stemcell-disk;
                file = "root.qcow2";
              };
              disk-determinism-resolute-aws = pkgs.callPackage ./build/checks/disk-determinism.nix {
                artifact = resolute-stemcell-aws-disk;
                file = "root.img";
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
                resolute-openstack-kvm = pkgs.callPackage ./build/stemcells/openstack-kvm.nix {
                  release = "resolute";
                };
                resolute-aws = pkgs.callPackage ./build/stemcells/aws.nix { release = "resolute"; };
              in
              {
                # PHASE 1: OS image (rootfs tarball)
                os-image = pkgs.callPackage ./build/rootfs/os-image.nix { };
                noble-rootfs = pkgs.callPackage ./build/rootfs/rootfs.nix { };

                # PHASE 2 (OpenStack/KVM)
                noble-stemcell-rootfs = noble-stemcell-rootfs;
                noble-stemcell-disk = noble-stemcell-disk;
                noble-stemcell = openstack-kvm;
                openstack-kvm = openstack-kvm;

                # PHASE 2 (AWS / xen, aws-raw heavy stemcell)
                os-image-aws = pkgs.callPackage ./build/rootfs/os-image.nix { infrastructure = "aws"; };
                noble-stemcell-aws-rootfs = noble-stemcell-aws-rootfs;
                noble-stemcell-aws-disk = noble-stemcell-aws-disk;
                noble-stemcell-aws = aws;
                aws = aws;

                # PHASE 1/2 (Resolute)
                os-image-resolute = pkgs.callPackage ./build/rootfs/os-image.nix { release = "resolute"; };
                os-image-resolute-aws = pkgs.callPackage ./build/rootfs/os-image.nix {
                  infrastructure = "aws";
                  release = "resolute";
                };
                resolute-stemcell-rootfs = resolute-stemcell-rootfs;
                resolute-stemcell-disk = resolute-stemcell-disk;
                resolute-stemcell = resolute-openstack-kvm;
                resolute-openstack-kvm = resolute-openstack-kvm;
                resolute-stemcell-aws-rootfs = resolute-stemcell-aws-rootfs;
                resolute-stemcell-aws-disk = resolute-stemcell-aws-disk;
                resolute-stemcell-aws = resolute-aws;
                resolute-aws = resolute-aws;

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
