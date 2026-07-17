# OpenStack/KVM infrastructure descriptor. Pure data. YAML fragments are
# transcribed verbatim from the previous package.nix conditionals; their
# indentation is load-bearing (see package.nix INDENTATION CONTRACT comments).
{
  infrastructure = "openstack";
  hypervisor = "kvm";
  diskFormat = "qcow2";
  diskFilename = "root.qcow2";
  nameSuffix = "";

  # IaaS-specific stage directory names, imported by stages/default.nix.
  infraStageNames = [ "openstack-agent-settings" ];

  # package.nix manifest fragments (byte-identical to prior conditionals).
  stemcellFormatsYaml = "  - openstack-qcow2\n  - openstack-raw";
  diskFormatValue = "qcow2";
  extraCloudPropsYaml = "auto_disk_config: true";
}
