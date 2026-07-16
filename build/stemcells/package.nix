# mk-stemcell.nix
# Pure derivation: package bootable qcow2 disk into a 6-member BOSH stemcell tarball.
# Input: bootableDisk (path to root.qcow2)
# Output: $out/bosh-stemcell-VERSION-INFRASTRUCTURE-HYPERVISOR-OS-VERSION.tgz
{
  stdenv,
  lib,
  coreutils,
  gnutar,
  gzip,
  qemu,
}:
{
  bootableDisk,
  metadata,
  version ? "0.0.1-nix",
  os ? "ubuntu",
  osVersion ? "noble",
  infrastructure ? "openstack",
  hypervisor ? "kvm",
}:

let
  # Compute stemcell archive filename per upstream convention:
  # bosh-stemcell-VERSION-INFRASTRUCTURE-HYPERVISOR-OS-OSVERSION.tgz
  stemcellFilename = "bosh-stemcell-${version}-${infrastructure}-${hypervisor}-${os}-${osVersion}.tgz";

  # Infrastructure-specific manifest fields (mirrors upstream
  # bosh/stemcell/infrastructure.rb + stemcell_packager.rb).
  #
  # INDENTATION CONTRACT (load-bearing): this value CARRIES its own
  # 2-space YAML list indent ("  - ..."). Its heredoc placeholder line
  # (`${stemcellFormatsYaml}`) sits at base indent, which renders at
  # column 0 after Nix ''-string common-indent stripping. Changing
  # either the leading spaces on that heredoc line OR the spaces inside
  # this value will break the manifest YAML nesting.
  stemcellFormatsYaml =
    if infrastructure == "aws" then "  - aws-raw" else "  - openstack-qcow2\n  - openstack-raw";

  diskFormatValue = if infrastructure == "aws" then "raw" else "qcow2";

  # Trailing cloud_properties entries appended after `architecture`
  # (upstream additional_cloud_properties).
  #
  # INDENTATION CONTRACT (load-bearing): this value does NOT carry a
  # leading indent for its first line — the heredoc placeholder line
  # (`${extraCloudPropsYaml}`, 6 spaces → 2 after ''-strip) supplies the
  # cloud_properties key level. Any second line embeds `\n  ` to hold
  # that same 2-space level. Do not alter the heredoc placeholder line's
  # leading whitespace or the embedded `\n  ` here.
  extraCloudPropsYaml =
    if infrastructure == "aws" then
      "root_device_name: /dev/sda1\n  boot_mode: uefi-preferred"
    else
      "auto_disk_config: true";
in

stdenv.mkDerivation {
  name = "stemcell-packaging";

  buildInputs = [
    coreutils
    gnutar
    gzip
    qemu
  ];

  buildCommand = ''
        set -exuo pipefail
        
        export SOURCE_DATE_EPOCH=0
        
        # Setup working directory
        mkdir -p $out/work
        cd $out/work
        
        # Copy qcow2 to root.img (qcow2 file named as root.img, per BOSH OpenStack convention)
        ${coreutils}/bin/cp ${bootableDisk} root.img
        
        # Create inner image tarball (deterministic: sorted, fixed ownership, fixed mtime)
        ${gnutar}/bin/tar --sort=name --owner=0 --group=0 --numeric-owner \
          --mtime="@$SOURCE_DATE_EPOCH" --format=gnu -cf - root.img \
          | ${gzip}/bin/gzip -n -1 > image
        
        # Compute SHA-1 of the inner image tarball (NOT root.img!)
        # This value goes into stemcell.MF
        imageSha1=$(${coreutils}/bin/sha1sum image | ${coreutils}/bin/cut -d' ' -f1)
        echo "$imageSha1" > image.sha1
        echo "Image SHA-1: $imageSha1"
        
        # Generate stemcell.MF (YAML manifest)
        # Note: using cat << EOF (not <<'EOF') to allow variable substitution
        cat > stemcell.MF <<EOF
    name: bosh-${infrastructure}-${hypervisor}-${os}-${osVersion}
    version: ${version}
    bosh_protocol: 1
    api_version: 3
    sha1: $imageSha1
    operating_system: ${os}-${osVersion}
    stemcell_formats:
    ${stemcellFormatsYaml}
    cloud_properties:
      name: bosh-${infrastructure}-${hypervisor}-${os}-${osVersion}
      version: ${version}
      infrastructure: ${infrastructure}
      hypervisor: ${hypervisor}
      disk: 5120
      disk_format: ${diskFormatValue}
      container_format: bare
      os_type: linux
      os_distro: ${os}
      architecture: x86_64
      ${extraCloudPropsYaml}
    EOF
        
        echo "Manifest created"
        
        # Copy real metadata members generated from the rootfs (apply-stages.nix)
        ${coreutils}/bin/cp ${metadata}/metadata/packages.txt packages.txt
        ${coreutils}/bin/cp ${metadata}/metadata/dev_tools_file_list.txt dev_tools_file_list.txt
        ${coreutils}/bin/cp ${metadata}/metadata/sbom.spdx.json sbom.spdx.json
        ${coreutils}/bin/cp ${metadata}/metadata/sbom.cdx.json sbom.cdx.json
        
        echo "Metadata members copied"
        
        # Verify all 6 required members exist
        expected_files=(
          "stemcell.MF"
          "packages.txt"
          "dev_tools_file_list.txt"
          "image"
          "sbom.spdx.json"
          "sbom.cdx.json"
        )
        
        for f in "''${expected_files[@]}"; do
          if [ ! -e "$f" ]; then
            echo "ERROR: Missing required file: $f"
            ls -la
            exit 1
          fi
        done
        
        echo "All 6 required members present"
        
        # Create final stemcell tarball with exactly the 6 members in spec order
        # (matching upstream stemcell_packager.rb:84)
        # Use deterministic tar flags: sorted, fixed ownership, fixed mtime, single-threaded gzip
        ${gnutar}/bin/tar --sort=name --owner=0 --group=0 --numeric-owner \
          --mtime="@$SOURCE_DATE_EPOCH" --format=gnu \
          --use-compress-program="${gzip}/bin/gzip -n" \
          -cf stemcell.tgz \
          stemcell.MF \
          packages.txt \
          dev_tools_file_list.txt \
          image \
          sbom.spdx.json \
          sbom.cdx.json
        
        # Move to output directory with correct filename
        mv stemcell.tgz $out/${stemcellFilename}
        
        echo "Stemcell tarball created: $out/${stemcellFilename}"
        ls -lh $out/${stemcellFilename}
        
        cd $out
        ${gnutar}/bin/tar -tzf ${stemcellFilename} | head -10
        echo "Stemcell package complete"
  '';
}
