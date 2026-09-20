#!/data/data/com.termux/files/usr/bin/bash
set -Eeuo pipefail

WORK="$HOME/WEAR5"
BUILD="/storage/emulated/0/Download/WEAR5_FIRST_BUILD"
IMG="$BUILD/images"
LOGICAL="$IMG/logical"
META="$BUILD/meta"
INFO="$META/target_dynamic_info.txt"
OUT="$IMG/super.img"

die(){ echo; echo "BLOCKER=$*"; exit 2; }
kv(){ awk -F= -v k="$1" '$1==k{print substr($0,index($0,"=")+1);exit}' "$INFO"; }

SUPER_SIZE="${1:-}"
[ -n "$SUPER_SIZE" ] || die "uso: $0 SUPER_SIZE_BYTES"
[[ "$SUPER_SIZE" =~ ^[0-9]+$ ]] || die "SUPER_SIZE_non_numerico"
(( SUPER_SIZE % 4096 == 0 )) || die "SUPER_SIZE_non_allineato_4096"

LP_GROUPS="$(kv super_partition_groups || true)"
DYNAMIC_LIST="$(kv dynamic_partition_list || true)"
[ -n "$LP_GROUPS" ] || die "gruppi_mancanti"
[ -n "$DYNAMIC_LIST" ] || die "partizioni_mancanti"

command -v lpmake >/dev/null || die "lpmake_non_disponibile"

group_for_part(){
  local p="$1" g q list
  for g in $LP_GROUPS; do
    list="$(kv "${g}_partition_list" || true)"
    for q in $list; do
      [ "$q" = "$p" ] && { echo "$g"; return 0; }
    done
  done
  return 1
}

TOTAL_GROUP_MAX=0
LPM_ARGS=()
for G in $LP_GROUPS; do
  GS="$(kv "${G}_size" || true)"
  [[ "$GS" =~ ^[0-9]+$ ]] || die "dimensione_gruppo_${G}_invalida"
  TOTAL_GROUP_MAX=$((TOTAL_GROUP_MAX + GS))
  LPM_ARGS+=(--group "${G}:${GS}")
done

# Il device deve avere spazio per gruppi + metadata/reserved area.
(( SUPER_SIZE > TOTAL_GROUP_MAX )) || die "SUPER_SIZE_${SUPER_SIZE}_non_superiore_ai_gruppi_${TOTAL_GROUP_MAX}"

SUM_IMAGES=0
for P in $DYNAMIC_LIST; do
  F="$LOGICAL/$P.img"
  [ -f "$F" ] || die "immagine_mancante_${P}"
  SZ="$(stat -c %s "$F")"
  G="$(group_for_part "$P" || true)"
  [ -n "$G" ] || die "gruppo_non_trovato_${P}"
  SUM_IMAGES=$((SUM_IMAGES + SZ))
  LPM_ARGS+=(--partition "${P}:readonly:${SZ}:${G}" --image "${P}=${F}")
done

rm -f "$OUT"

echo "SUPER_SIZE=$SUPER_SIZE"
echo "GROUP_MAX_TOTAL=$TOTAL_GROUP_MAX"
echo "IMAGES_TOTAL=$SUM_IMAGES"
echo "HEADROOM_GROUP=$((TOTAL_GROUP_MAX-SUM_IMAGES))"

lpmake \
  --metadata-size 65536 \
  --metadata-slots 2 \
  --super-name super \
  --device "super:$SUPER_SIZE" \
  "${LPM_ARGS[@]}" \
  --output "$OUT" >/dev/null || die "lpmake_fallito"

ACTUAL="$(stat -c %s "$OUT")"
[ "$ACTUAL" -eq "$SUPER_SIZE" ] || die "super_generato_${ACTUAL}_atteso_${SUPER_SIZE}"

sha256sum "$OUT" > "$BUILD/SUPER_SHA256.txt"

python - "$BUILD/BUILD_INFO.txt" "$SUPER_SIZE" <<'PY'
import sys
p,size=sys.argv[1:3]
try:
    lines=open(p,encoding="utf-8").read().splitlines()
except FileNotFoundError:
    lines=[]
out=[]
seen=set()
for line in lines:
    if line.startswith("SUPER_STATUS="):
        line="SUPER_STATUS=BUILT"
        seen.add("status")
    elif line.startswith("SUPER_SIZE="):
        line="SUPER_SIZE="+size
        seen.add("size")
    out.append(line)
if "status" not in seen: out.append("SUPER_STATUS=BUILT")
if "size" not in seen: out.append("SUPER_SIZE="+size)
open(p,"w",encoding="utf-8").write("\n".join(out)+"\n")
PY

echo
echo "SUPER_READY=$OUT"
echo "SUPER_SIZE=$SUPER_SIZE"
echo "SHA256=$(cut -d' ' -f1 "$BUILD/SUPER_SHA256.txt")"
echo "RECOVERY_INCLUDED=NO"
