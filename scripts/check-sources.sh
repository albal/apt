#!/usr/bin/env bash
# Check every *.sources file in the repository to see whether a suite
# matching the current Ubuntu LTS codename is available upstream.
#
# Output: Markdown written to stdout. The workflow appends this to
# $GITHUB_STEP_SUMMARY.
#
# The script is intentionally informational: it never exits non-zero
# because of upstream content (only on hard runtime errors).

set -euo pipefail

REPO_DIR="${1:-.}"
cd "$REPO_DIR"

# ---------------------------------------------------------------------------
# Determine the current Ubuntu LTS codename.
#
# changelogs.ubuntu.com/meta-release lists every Ubuntu release in
# RFC822-style stanzas. LTS releases are identified by an "LTS" suffix
# in the Version field (e.g. "26.04 LTS", "24.04.4 LTS"). We pick the
# stanza with the highest Version that is tagged as LTS and whose
# release month is not in the future.
#
# Note: meta-release-lts only advertises an LTS once its first point
# release is published (typically ~4 months after release), so it lags
# behind the actual current LTS. Using meta-release avoids that lag.
# The Supported field in meta-release can also lag for a newly released
# LTS, so it is intentionally not used for current-LTS selection.
# ---------------------------------------------------------------------------
META_URL="https://changelogs.ubuntu.com/meta-release"
META=$(curl -fsSL --retry 3 --max-time 30 "$META_URL" || true)
CURRENT_YY=$(date -u +%y)
CURRENT_MM=$(date -u +%m)

LTS_CODENAME=""
LTS_VERSION=""
if [[ -n "$META" ]]; then
  # Among stanzas that are tagged LTS in Version and not dated in the
  # future, pick the one with the numerically highest Version (YY.MM[.P]).
  read -r LTS_CODENAME LTS_VERSION < <(awk -v current_year="$CURRENT_YY" -v current_month="$CURRENT_MM" '
    BEGIN { RS=""; FS="\n"; best_year=-1; best_month=-1; best_point=-1 }
    {
      lts=0; dist=""; ver=""; vnum=""
      for (i=1;i<=NF;i++) {
        if ($i ~ /^Dist:/)    { dist=$i; sub(/^Dist:[[:space:]]*/,"",dist) }
        if ($i ~ /^Version:/) {
          ver=$i; sub(/^Version:[[:space:]]*/,"",ver)
          if (ver ~ /LTS/) lts=1
          vnum=ver; sub(/[[:space:]]*LTS.*$/,"",vnum)
        }
      }
      if (lts==1 && dist!="" && vnum ~ /^[0-9]+\.[0-9]+/) {
        n=split(vnum, parts, ".")
        year=parts[1]+0; month=parts[2]+0
        point=(n>=3 ? parts[3]+0 : 0)
        if (year > current_year || (year == current_year && month > current_month)) next
        if (year > best_year \
            || (year == best_year && month > best_month) \
            || (year == best_year && month == best_month && point > best_point)) {
          best_year=year; best_month=month; best_point=point
          best_dist=dist; best_vnum=vnum
        }
      }
    }
    END { if (best_dist!="") print best_dist, best_vnum }
  ' <<<"$META")
fi

if [[ -z "$LTS_CODENAME" ]]; then
  if (( 10#$CURRENT_YY > 26 || (10#$CURRENT_YY == 26 && 10#$CURRENT_MM >= 4) )); then
    echo "::warning::Could not determine current Ubuntu LTS from $META_URL; defaulting to 'resolute'"
    LTS_CODENAME="resolute"
    LTS_VERSION="26.04"
  else
    echo "::warning::Could not determine current Ubuntu LTS from $META_URL; defaulting to 'noble'"
    LTS_CODENAME="noble"
    LTS_VERSION="24.04"
  fi
fi

echo "# APT sources vs. current Ubuntu LTS"
echo
echo "Current Ubuntu LTS detected: **${LTS_CODENAME}** (${LTS_VERSION:-unknown version})"
echo
echo "_Generated: $(date -u +'%Y-%m-%d %H:%M:%S UTC')_"
echo

# Suites that are channel/flat names rather than distro codenames; we
# don't try to "upgrade" these.
NON_CODENAME_SUITES=" / ./ * stable main generic "

# Probe a URL with HEAD; fall back to a ranged GET if HEAD is not allowed.
probe_url() {
  local url="$1"
  local code
  code=$(curl -o /dev/null -sS -L --max-time 20 -w '%{http_code}' -I "$url" || echo 000)
  if [[ "$code" == "200" || "$code" == "301" || "$code" == "302" ]]; then
    echo "$code"
    return
  fi
  code=$(curl -o /dev/null -sS -L --max-time 20 -r 0-0 -w '%{http_code}' "$url" || echo 000)
  echo "$code"
}

# Normalise a base URI: strip trailing slash and any trailing /dists.
canonical_base() {
  local uri="$1"
  uri="${uri%/}"
  uri="${uri%/dists}"
  echo "$uri"
}

# Build the candidate Release URL for a given base URI and codename.
release_url() {
  local base="$1" suite="$2"
  echo "$(canonical_base "$base")/dists/${suite}/Release"
}

declare -a OUTDATED MATCHING SKIPPED FLAT UNREACHABLE

shopt -s nullglob
for f in *.sources; do
  # Parse RFC822-style stanzas: collect URIs and Suites lines.
  # A file may contain multiple stanzas separated by blank lines.
  awk -v file="$f" '
    BEGIN { RS=""; FS="\n" }
    {
      uris=""; suites=""
      for (i=1;i<=NF;i++) {
        line=$i
        if (line ~ /^[[:space:]]*#/) continue
        if (line ~ /^[Uu][Rr][Ii][Ss]:/) { sub(/^[^:]*:[[:space:]]*/,"",line); uris=line }
        else if (line ~ /^[Ss][Uu][Ii][Tt][Ee][Ss]:/) { sub(/^[^:]*:[[:space:]]*/,"",line); suites=line }
      }
      if (uris != "" && suites != "") print file "\t" uris "\t" suites
    }
  ' "$f"
done > /tmp/stanzas.tsv

# Disable pathname expansion so suites like "*" aren't expanded to filenames.
set -f
while IFS=$'\t' read -r file uris suites; do
  [[ -z "$file" ]] && continue
  for uri in $uris; do
    for suite in $suites; do
      entry="\`$file\` — \`$uri\` suite \`$suite\`"

      # Flat repositories (no dists/ tree).
      if [[ " $NON_CODENAME_SUITES " == *" $suite "* ]]; then
        if [[ "$suite" == "/" || "$suite" == "./" ]]; then
          FLAT+=("$entry (flat repository — no codename concept)")
        else
          SKIPPED+=("$entry (channel-style suite, codename N/A)")
        fi
        continue
      fi

      # Already on the current LTS codename.
      if [[ "$suite" == "$LTS_CODENAME" ]]; then
        MATCHING+=("$entry — already on current LTS")
        continue
      fi

      # Ubuntu archive suites such as "<codename>-updates", "<codename>-security",
      # "<codename>-backports": treat the prefix as the codename.
      base_suite="${suite%%-*}"
      lts_candidate="$LTS_CODENAME"
      if [[ "$suite" == *-* && "$base_suite" != "$suite" ]]; then
        lts_candidate="${LTS_CODENAME}${suite#${base_suite}}"
        if [[ "$base_suite" == "$LTS_CODENAME" ]]; then
          MATCHING+=("$entry — already on current LTS")
          continue
        fi
      fi

      url=$(release_url "$uri" "$lts_candidate")
      code=$(probe_url "$url")

      if [[ "$code" == "200" || "$code" == "301" || "$code" == "302" ]]; then
        OUTDATED+=("$entry → LTS suite \`$lts_candidate\` is available at $url")
      else
        UNREACHABLE+=("$entry — no LTS suite \`$lts_candidate\` published (HTTP $code at $url)")
      fi
    done
  done
done < /tmp/stanzas.tsv
set +f

print_section() {
  local title="$1"; shift
  local -a items=("$@")
  echo "## $title (${#items[@]})"
  echo
  if (( ${#items[@]} == 0 )); then
    echo "_None._"
  else
    for it in "${items[@]}"; do
      echo "- $it"
    done
  fi
  echo
}

print_section "🔔 Updates available — newer LTS suite published upstream" "${OUTDATED[@]}"
print_section "✅ Already on current LTS"                                  "${MATCHING[@]}"
print_section "❔ No LTS suite found upstream"                             "${UNREACHABLE[@]}"
print_section "➖ Flat repositories (no codename)"                          "${FLAT[@]}"
print_section "➖ Channel-style suites (codename not applicable)"           "${SKIPPED[@]}"
