# mk-stemcell.nix
# Pure derivation: package bootable qcow2 disk into a 6-member BOSH stemcell tarball.
# Input: bootableDisk (path to root.qcow2)
# Output: $out/bosh-stemcell-VERSION-INFRASTRUCTURE-HYPERVISOR-OS-VERSION.tgz
{ stdenv
, lib
, coreutils
, gnutar
, gzip
, pigz
, qemu
}:
{ bootableDisk
, version ? "0.0.1-nix"
, os ? "ubuntu"
, osVersion ? "noble"
, infrastructure ? "openstack"
, hypervisor ? "kvm"
}:

let
  # Compute stemcell archive filename per upstream convention:
  # bosh-stemcell-VERSION-INFRASTRUCTURE-HYPERVISOR-OS-OSVERSION.tgz
  stemcellFilename = "bosh-stemcell-${version}-${infrastructure}-${hypervisor}-${os}-${osVersion}.tgz";
in

stdenv.mkDerivation {
  name = "stemcell-packaging";
  
  buildInputs = [ coreutils gnutar gzip pigz qemu ];
  
  buildCommand = ''
    set -exuo pipefail
    
    # Setup working directory
    mkdir -p $out/work
    cd $out/work
    
    # Copy qcow2 to root.img (qcow2 file named as root.img, per BOSH OpenStack convention)
    ${coreutils}/bin/cp ${bootableDisk} root.img
    
    # Create inner image tarball (pigz-compressed, as required by BOSH CPI)
    ${gnutar}/bin/tar -cf - root.img | ${pigz}/bin/pigz -1 > image
    
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
  - openstack-qcow2
  - openstack-raw
cloud_properties:
  name: bosh-${infrastructure}-${hypervisor}-${os}-${osVersion}
  version: ${version}
  infrastructure: ${infrastructure}
  hypervisor: ${hypervisor}
  disk: 5120
  disk_format: qcow2
  container_format: bare
  os_type: linux
  os_distro: ${os}
  architecture: x86_64
  auto_disk_config: true
EOF
    
    echo "Manifest created"
    
    # Create minimal stub files (director checks presence, ignores content per R6)
    touch packages.txt
    touch dev_tools_file_list.txt
    
    # Create stub SBOM files (empty JSON objects)
    echo '{}' > sbom.spdx.json
    echo '{}' > sbom.cdx.json
    
    echo "Stub files created"
    
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
    ${gnutar}/bin/tar -zcf stemcell.tgz \
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
