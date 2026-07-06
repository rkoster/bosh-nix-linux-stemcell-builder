# Package source for the Noble POC build.
# snapshot.ubuntu.com was unreachable from the host (503) at build time, so we
# fall back to the live archive. This is spec-compliant: the Serverspec oracle
# (bosh-stemcell/spec/os_image/ubuntu_spec.rb:35-37) accepts archive.ubuntu.com.
# Trade-off: NOT point-in-time reproducible; hashes float with the live index.
# Revisit for M2 once a stable snapshot timestamp is confirmed.
{
  urlPrefix = "http://archive.ubuntu.com/ubuntu";
  codename = "noble";
  components = [ "main" "universe" "multiverse" ];
}
