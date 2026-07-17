#!/usr/bin/env bash
set -euo pipefail

# Verify the Resolute rootfs matches the upstream os_image spec assertions.
# Usage: resolute-os-image-spec.sh <rootfs-staged.tar.gz> <ref-spec-file>
tarball="$1"
spec="$2"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

tar -xzf "$tarball" -C "$work" \
  etc/passwd etc/group etc/gshadow etc/pam.d/common-password 2>/dev/null ||
  tar -xzf "$tarball" -C "$work" \
    ./etc/passwd ./etc/group ./etc/gshadow ./etc/pam.d/common-password

# gshadow ships mode 0000; ensure the extracting user can read it.
chmod -R u+rwX "$work"

fail=0
check_eql() {
  local label="$1" want="$2" got="$3"
  if diff -u <(printf '%s\n' "$want") <(printf '%s\n' "$got") >/tmp/spec-diff 2>&1; then
    echo "OK   $label"
  else
    echo "FAIL $label"
    cat /tmp/spec-diff
    fail=1
  fi
}

# Spec slices are indented in the heredoc; strip the leading 8 spaces.
want_passwd="$(sed -n '357,385p' "$spec" | sed 's/^        //')"
want_group="$(sed -n '427,488p' "$spec" | sed 's/^        //')"
want_gshadow="$(sed -n '494,555p' "$spec" | sed 's/^        //')"

check_eql "/etc/passwd" "$want_passwd" "$(cat "$work/etc/passwd")"
check_eql "/etc/group" "$want_group" "$(cat "$work/etc/group")"
check_eql "/etc/gshadow" "$want_gshadow" "$(cat "$work/etc/gshadow")"

if grep -qP '^session\toptional\t+pam_lastlog2\.so showfailed' "$work/etc/pam.d/common-password"; then
  echo "OK   pam_lastlog2 active line"
else
  echo "FAIL pam_lastlog2 active line missing"
  fail=1
fi

if grep -qE '(^|:)_runit-log(:|$)' "$work/etc/passwd" "$work/etc/group"; then
  echo "FAIL _runit-log present (runit should be removed)"
  fail=1
else
  echo "OK   _runit-log absent"
fi

exit "$fail"
