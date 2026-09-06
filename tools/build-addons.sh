#!/bin/bash
#
# Build every add-on this repository publishes, for every target, with
# LibreELEC's buildsystem, and file the results under docs/.
#
#   tools/build-addons.sh                     # every target
#   tools/build-addons.sh --arch x86_64       # just the one architecture
#   tools/build-addons.sh --series omega      # just the one Kodi release
#   tools/build-addons.sh --pin v0.1.3        # move LibreELEC's pin first
#   tools/build-addons.sh --commit            # and commit docs/
#
# LE_PIERS and LE_OMEGA point at the LibreELEC checkouts, ADDONS=... at what
# to build.
#
set -o errexit -o nounset -o pipefail

HERE=$(cd "$(dirname "$0")/.." && pwd)
ADDONS=${ADDONS:-inputstream.airplay}

# One LibreELEC checkout per Kodi release, each kept for this and nothing else.
# What gets published has to be built from a tree holding nothing but
# LibreELEC and the add-on package: a working tree with local kernel or Kodi
# patches in it builds something no user is running, and a patch meant for one
# board stops the other targets building at all. See "The build trees" in the
# README.
declare -A TREES=(
  [piers]="${LE_PIERS:-${HOME}/projects/LibreELEC-addons}"    # LibreELEC master
  [omega]="${LE_OMEGA:-${HOME}/projects/LibreELEC-addons-12}" # libreelec-12.2
)

# Kodi release, then LibreELEC project, device, architecture, and last the
# architecture this repository files the result under.
#
# The device fixes the CPU the code is tuned for, and Kodi picks a build by
# architecture alone, so these are LibreELEC's own lowest-common-denominator
# add-on targets -- the ones every other project points its users at. Building
# aarch64 as RPi5 instead would tune for Cortex-A76, and Kodi would offer the
# result to a Cortex-A53 box and crash on it.
TARGETS=(
  "piers Generic Generic x86_64  x86_64"
  "piers ARM     ARMv8   aarch64 aarch64"
  "piers ARM     ARMv7   arm     armv7"
  "omega Generic Generic x86_64  x86_64"
  "omega ARM     ARMv8   aarch64 aarch64"
  "omega ARM     ARMv7   arm     armv7"
)

only_arch=""
only_series=""
pin=""
commit=no

while [ $# -gt 0 ]; do
  case "$1" in
    --arch) only_arch="$2"; shift 2 ;;
    --series) only_series="$2"; shift 2 ;;
    --pin) pin="$2"; shift 2 ;;
    --commit) commit=yes; shift ;;
    -h|--help) sed -n '3,13p' "$0" | sed 's/^# \?//'; exit 0 ;;
    *) echo "unknown argument $1" >&2; exit 1 ;;
  esac
done

selected=()
for target in "${TARGETS[@]}"; do
  read -r series _ _ _ repo_arch <<<"${target}"
  [ -z "${only_arch}" ] || [ "${only_arch}" = "${repo_arch}" ] || continue
  [ -z "${only_series}" ] || [ "${only_series}" = "${series}" ] || continue
  selected+=("${target}")
done

[ ${#selected[@]} -gt 0 ] || { echo "no target matches" >&2; exit 1; }

series_selected=$(printf '%s\n' "${selected[@]}" | cut -d' ' -f1 | sort -u)
for series in ${series_selected}; do
  [ -d "${TREES[$series]}" ] || {
    echo "no LibreELEC checkout for ${series} at ${TREES[$series]}" >&2; exit 1; }
done

# Each tree pins the add-on separately, so a release has to be written into
# every one of them.
if [ -n "${pin}" ]; then
  for series in ${series_selected}; do
    cd "${TREES[$series]}"
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
      echo "==> ${series}: pinning ${addon} to ${pin} (${sha})"
      sed -i "s|^PKG_VERSION=.*|PKG_VERSION=\"${sha}\"|" "${package}"
      # Downloads the new tarball and writes its checksum back into package.mk.
      CHANGE_HASH=yes scripts/get "${addon}"
    done
  done
fi

built=()

for target in "${selected[@]}"; do
  read -r series project device arch repo_arch <<<"${target}"
  tree="${TREES[$series]}"
  cd "${tree}"
  addon_version=$(sed -n 's/^ *ADDON_VERSION="\(.*\)"/\1/p' distributions/LibreELEC/version)

  echo "==> ${series}: ${project}/${device} ${arch} (${repo_arch})"
  for addon in ${ADDONS}; do
    # LibreELEC builds the add-on version as <its addon.xml version>.<PKG_REV>,
    # so naming the flavour in PKG_REV carries it into both the version and the
    # zip: inputstream.airplay-0.1.3.1+omega.aarch64.zip. Six builds of one
    # add-on otherwise share three filenames, and Kodi's package cache is keyed
    # on the filename alone -- it will install a cached zip of the right name
    # whatever is inside it.
    #
    # A dot, never a dash: CAddonVersion takes everything after the first dash
    # as the revision, which would leave every architecture comparing equal.
    package="packages/mediacenter/kodi-binary-addons/${addon}/package.mk"
    rev=$(sed -n 's/^PKG_REV="\([0-9]*\).*/\1/p' "${package}")
    sed -i "s|^PKG_REV=.*|PKG_REV=\"${rev}+${series}.${repo_arch}\"|" "${package}"

    # LibreELEC skips an add-on it has already built, so drop both the stamp
    # and the previous output to make a rebuild actually rebuild.
    PROJECT="${project}" DEVICE="${device}" ARCH="${arch}" scripts/clean "${addon}"
    rm -rf "target/addons/${addon_version}/${device}/${arch}/${addon}"
  done

  PROJECT="${project}" DEVICE="${device}" ARCH="${arch}" scripts/create_addon ${ADDONS}

  for addon in ${ADDONS}; do
    zip=$(ls -1 "target/addons/${addon_version}/${device}/${arch}/${addon}/${addon}-"*.zip)
    "${HERE}/tools/make_repo.py" add "${zip}" --series "${series}" --arch "${repo_arch}"
    built+=("${series}/${repo_arch} $(basename "${zip}")")
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
