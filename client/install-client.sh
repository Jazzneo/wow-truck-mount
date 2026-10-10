#!/usr/bin/env bash
# =============================================================================
#  Truck Mount - PLAYER install (Linux / Steam Deck)
#  Copies the truck patch into your WoW 3.3.5a Data folder and clears the Cache.
#
#    bash install-client.sh                    find WoW by itself
#    bash install-client.sh /path/to/WoW       use this WoW folder
#    bash install-client.sh --uninstall [dir]  remove the truck patch again
# =============================================================================
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PATCH="$HERE/patch-5.MPQ"
UNINSTALL=0
WOW=""
for a in "$@"; do
  case "$a" in
    --uninstall|-u) UNINSTALL=1 ;;
    -h|--help) sed -n '2,9p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) WOW="$a" ;;
  esac
done

if [ -t 1 ]; then G=$'\e[32m'; R=$'\e[31m'; Y=$'\e[33m'; B=$'\e[1m'; N=$'\e[0m'; else G=; R=; Y=; B=; N=; fi
ok()   { echo "${G}$*${N}"; }
warn() { echo "${Y}$*${N}"; }
die()  { echo; echo "${R}ERROR: $*${N}"; exit 1; }

[ "$UNINSTALL" = 1 ] || [ -f "$PATCH" ] || die "patch-5.MPQ is missing. Keep it in the same folder as this script."

# ----------------------------------------------------------------------------- find WoW
find_ci() {  # find_ci DIR NAME  -> path of a direct child named NAME (any case)
  local f; for f in "$1"/*; do [ "$(basename "$f" | tr 'A-Z' 'a-z')" = "$(echo "$2" | tr 'A-Z' 'a-z')" ] && { echo "$f"; return 0; }; done; return 1
}
is_wow() { [ -d "$1" ] && find_ci "$1" "wow.exe" >/dev/null && find_ci "$1" "data" >/dev/null; }

echo "${B}== 1/3  Finding your WoW 3.3.5a folder${N}"
if [ -n "$WOW" ]; then
  [ -f "$WOW" ] && WOW="$(dirname "$WOW")"          # they gave Wow.exe itself
  is_wow "$WOW" || die "No Wow.exe + Data folder in: $WOW"
else
  mapfile -t hits < <(
    for root in "$HERE/.." "$HERE/../.." "$HOME" /run/media /media /mnt; do
      # depth 11 reaches Steam/Proton prefixes: ~/.local/share/Steam/steamapps/compatdata/<id>/pfx/drive_c/...
      [ -d "$root" ] && { echo "  searching $root ..." >&2; find "$root" -xdev -maxdepth 11 \( -name proc -o -name node_modules -o -name .cache \) -prune -o -iname wow.exe -type f -print 2>/dev/null; }
    done | while read -r exe; do d="$(dirname "$exe")"; is_wow "$d" && realpath "$d"; done | sort -u)
  if [ ${#hits[@]} -eq 0 ]; then
    die "WoW not found. Run it like this:  bash install-client.sh /path/to/your/WoW/folder"
  elif [ ${#hits[@]} -gt 1 ]; then
    echo "Found more than one WoW folder:"
    for i in "${!hits[@]}"; do echo "  $((i+1))) ${hits[$i]}"; done
    read -r -p "Which one do you play with? [1-${#hits[@]}] " n
    [[ "$n" =~ ^[0-9]+$ ]] && [ "$n" -ge 1 ] && [ "$n" -le ${#hits[@]} ] || die "Invalid choice."
    WOW="${hits[$((n-1))]}"
  else
    WOW="${hits[0]}"
  fi
fi
DATA="$(find_ci "$WOW" data)"
ok "Using $WOW"

# ----------------------------------------------------------------------------- patch
same_file() { cmp -s "$1" "$2"; }
# every truck patch ever released (md5), so older versions get replaced, not duplicated
KNOWN="3b5052290da276b4244b9ff970de40cf 8387ac3404978353458d9d90fa792a6e c48da617122aff79ee0b9ff9bac0f1a6 f5ced18351ad483a4363be07601ded5d fcd993c0be67705b97336d8bbdc34478"
md5of() { if command -v md5sum >/dev/null; then md5sum "$1" | cut -d' ' -f1; else md5 -q "$1" 2>/dev/null; fi; }
is_ours() { local h; h="$(md5of "$1")"; [ -n "$h" ] && case " $KNOWN " in *" $h "*) return 0 ;; esac; return 1; }

if [ "$UNINSTALL" = 1 ]; then
  echo "${B}== 2/3  Removing the truck patch${N}"
  removed=0
  for f in "$DATA"/[Pp][Aa][Tt][Cc][Hh]-?.[Mm][Pp][Qq]; do
    [ -f "$f" ] || continue
    if { [ -f "$PATCH" ] && same_file "$f" "$PATCH"; } || is_ours "$f"; then
      rm -f "$f" && ok "Removed $(basename "$f")" && removed=1
    fi
  done
  [ "$removed" = 1 ] || warn "No truck patch found in $DATA (already removed?)."
else
  echo "${B}== 2/3  Copying the truck patch${N}"
  TARGET=""
  # already installed (same or older truck patch)? -> replace it in place
  for f in "$DATA"/[Pp][Aa][Tt][Cc][Hh]-?.[Mm][Pp][Qq]; do
    [ -f "$f" ] || continue
    if same_file "$f" "$PATCH" || is_ours "$f"; then TARGET="$f"; break; fi
  done
  if [ -z "$TARGET" ]; then
    # first free name, starting at patch-5; never overwrite somebody else's patch
    for c in 5 6 7 8 9 A B C D E F G H I J K L M N O P Q R S T U V W X Y Z; do
      taken=0
      for f in "$DATA"/[Pp][Aa][Tt][Cc][Hh]-"$c".[Mm][Pp][Qq] "$DATA"/[Pp][Aa][Tt][Cc][Hh]-"$(echo $c | tr A-Z a-z)".[Mm][Pp][Qq]; do
        [ -e "$f" ] && taken=1
      done
      [ "$taken" = 0 ] && { TARGET="$DATA/patch-$c.MPQ"; break; }
    done
    [ -n "$TARGET" ] || die "Every patch name from patch-5 to patch-Z is taken in $DATA."
    [ "$(basename "$TARGET")" = "patch-5.MPQ" ] || warn "patch-5.MPQ is already used by another mod, so the truck goes in as $(basename "$TARGET")."
  fi
  cp -f "$PATCH" "$TARGET" || die "Could not copy into $DATA (is WoW running? close it first)."
  ok "Installed as $TARGET"
fi

# ----------------------------------------------------------------------------- cache
echo "${B}== 3/3  Clearing the WoW Cache${N}"
CACHE="$(find_ci "$WOW" cache || true)"
if [ -n "$CACHE" ] && [ -d "$CACHE" ]; then rm -rf "$CACHE" && ok "Cache cleared."; else ok "No Cache folder (fine)."; fi

echo
if [ "$UNINSTALL" = 1 ]; then
  ok "${B}UNINSTALLED.${N}${G} Restart WoW."
else
  ok "${B}ALL DONE.${N}${G} Start WoW, open Spellbook > Mounts:"
  echo '  "Truck with Lights" and "Truck with No Lights" - drag them to your action bar.'
  echo "  (The server must have the truck installed too - ask your server admin.)"
fi
