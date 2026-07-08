require "open3"
require "shellwords"

module ShelloutTypes
  class Chroot
    @@chroot_dir = ""

    def self.chroot_dir=(dir)
      @@chroot_dir = dir
    end

    def self.unmount_proc
      dir = @@chroot_dir
      return if dir.empty?
      system("sudo", "umount", "#{dir}/proc", [:out, :err] => "/dev/null")
    end

    def initialize(dir = nil)
      @chroot_dir = dir unless dir.nil?
    end

    def run(*cmd)
      cmd.unshift("mknod -m 666 /dev/urandom c 1 9 2>/dev/null;")
      cmd.unshift("mknod -m 666 /dev/random c 1 8 2>/dev/null;")
      inner = cmd.join(" ")
      # Embed the calling process's PATH so it survives sudo's env_reset.
      # Without this, sudo resets PATH to a minimal set that omits Nix store
      # paths, causing mkdir/mount/chroot to be "not found".
      embedded_path = ENV.fetch("PATH", "/usr/bin:/bin:/usr/sbin:/sbin")
      wrapper = <<~SH.strip
        export PATH="#{embedded_path}"
        if ! mountpoint -q #{chroot_dir}/proc 2>/dev/null; then
          mkdir -p #{chroot_dir}/proc
          mount -t proc proc #{chroot_dir}/proc
        fi
        chroot #{chroot_dir} /bin/bash -c #{inner.shellescape}
      SH
      # Use bash and sudo from PATH (for Nix compatibility)
      bash_path = `which bash`.strip
      sudo_path = "/run/wrappers/bin/sudo"  # explicit path to host sudo with setuid
      stdout, stderr, status = Open3.capture3(sudo_path, bash_path, "-c", wrapper)
      [stdout, stderr, status.exitstatus]
    end

    def join(path)
      ::File.join(chroot_dir, path)
    end

    def chroot_dir
      @chroot_dir || @@chroot_dir
    end
  end
end
