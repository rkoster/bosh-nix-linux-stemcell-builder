# AWS infrastructure descriptor. Pure data. YAML fragments transcribed verbatim
# from the previous package.nix conditionals (indentation is load-bearing).
{
  infrastructure = "aws";
  hypervisor = "xen";
  diskFormat = "raw";
  diskFilename = "root.img";
  nameSuffix = "-aws";

  infraStageNames = [
    "aws-agent-settings"
    "udev-aws-rules"
  ];

  stemcellFormatsYaml = "  - aws-raw";
  diskFormatValue = "raw";
  extraCloudPropsYaml = "root_device_name: /dev/sda1\n  boot_mode: uefi-preferred";
}
