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
LE=${LE:-${HOME}/projects/LibreELEC.tv}
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
    sha=$(git ls-remote "${site}" "${pin}^{}" "${pin}" | head -1 | cut -f1)
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
