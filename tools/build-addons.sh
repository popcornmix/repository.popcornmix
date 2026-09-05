#!/bin/bash
#
# Build every add-on this repository publishes, for every target, with
# LibreELEC's buildsystem, and file the results under docs/.
#
#   tools/build-addons.sh                     # every target
#   tools/build-addons.sh --arch x86_64       # just the one
#   tools/build-addons.sh --pin v0.1.3        # move LibreELEC's pin first
#   tools/build-addons.sh --commit            # and commit docs/
#
# LE=... points at the LibreELEC checkout, ADDONS=... at what to build.
#
set -o errexit -o nounset -o pipefail

HERE=$(cd "$(dirname "$0")/.." && pwd)

# A LibreELEC checkout kept for this and nothing else. What gets published has
# to be built from a tree with nothing in it but LibreELEC and the add-on
# package -- a working tree with local kernel or Kodi patches in it builds
# something no user is running, and patches meant for one board stop the other
# targets building at all. See "The build tree" in the README.
LE=${LE:-${HOME}/projects/LibreELEC-addons}
ADDONS=${ADDONS:-inputstream.airplay}
SERIES=${SERIES:-piers}

# LibreELEC project, device, LibreELEC architecture, repository architecture.
#
# The device fixes the CPU the code is tuned for, and Kodi picks a build by
# architecture alone, so these are LibreELEC's own lowest-common-denominator
# add-on targets -- the ones every other project points its users at. Building
# aarch64 as RPi5 instead would tune for Cortex-A76, and Kodi would offer the
# result to a Cortex-A53 box and crash on it.
TARGETS=(
  "Generic Generic x86_64  x86_64"
  "ARM     ARMv8   aarch64 aarch64"
  "ARM     ARMv7   arm     armv7"
)

only_arch=""
pin=""
commit=no

while [ $# -gt 0 ]; do
  case "$1" in
    --arch) only_arch="$2"; shift 2 ;;
    --pin) pin="$2"; shift 2 ;;
    --commit) commit=yes; shift ;;
    -h|--help) sed -n '3,12p' "$0" | sed 's/^# \?//'; exit 0 ;;
    *) echo "unknown argument $1" >&2; exit 1 ;;
  esac
done

[ -d "${LE}" ] || { echo "no LibreELEC checkout at ${LE}" >&2; exit 1; }
cd "${LE}"

addon_version=$(sed -n 's/^ *ADDON_VERSION="\(.*\)"/\1/p' distributions/LibreELEC/version)

if [ -n "${pin}" ]; then
  for addon in ${ADDONS}; do
    package="packages/mediacenter/kodi-binary-addons/${addon}/package.mk"
    site=$(sed -n 's/^PKG_SITE="\(.*\)"/\1/p' "${package}")
    if [[ "${pin}" =~ ^[0-9a-f]{40}$ ]]; then
      sha="${pin}"
    else
      # An annotated tag has to be peeled, or the recorded version is the tag
      # object rather than a commit. Only annotated tags answer to ^{}, so a
      # branch or a lightweight tag falls through to the second query.
      sha=$(git ls-remote "${site}" "${pin}^{}" | head -1 | cut -f1)
      [ -n "${sha}" ] || sha=$(git ls-remote "${site}" "${pin}" | head -1 | cut -f1)
    fi
    [ -n "${sha}" ] || { echo "${addon}: no such ref ${pin} at ${site}" >&2; exit 1; }
    echo "==> ${addon}: pinning to ${pin} (${sha})"
    sed -i "s|^PKG_VERSION=.*|PKG_VERSION=\"${sha}\"|" "${package}"
    # Downloads the new tarball and writes its checksum back into package.mk.
    CHANGE_HASH=yes scripts/get "${addon}"
  done
fi

built=()

for target in "${TARGETS[@]}"; do
  read -r project device arch repo_arch <<<"${target}"
  [ -z "${only_arch}" ] || [ "${only_arch}" = "${repo_arch}" ] || continue

  echo "==> ${project}/${device} ${arch} (${repo_arch})"
  for addon in ${ADDONS}; do
    # LibreELEC skips an add-on it has already built, so drop both the stamp
    # and the previous output to make a rebuild actually rebuild.
    PROJECT="${project}" DEVICE="${device}" ARCH="${arch}" scripts/clean "${addon}"
    rm -rf "target/addons/${addon_version}/${device}/${arch}/${addon}"
  done

  PROJECT="${project}" DEVICE="${device}" ARCH="${arch}" scripts/create_addon ${ADDONS}

  for addon in ${ADDONS}; do
    zip=$(ls -1 "target/addons/${addon_version}/${device}/${arch}/${addon}/${addon}-"*.zip)
    "${HERE}/tools/make_repo.py" add "${zip}" --series "${SERIES}" --arch "${repo_arch}"
    built+=("${repo_arch} $(basename "${zip}")")
  done
done

echo
echo "built:"
printf '  %s\n' "${built[@]}"

if [ "${commit}" = yes ]; then
  cd "${HERE}"
  git add -A docs
  git diff --cached --quiet && { echo "nothing changed"; exit 0; }
  git commit -m "Publish $(printf '%s, ' "${built[@]}" | sed 's/, $//')"
  echo "committed; push when you are happy with it"
fi
