#!/sbin/sh
#GQJZJY
PKG="$1"

if [ -e /proc/$$/fd/4 ]; then
    OUTFD=4
else
    OUTFD=1
fi

ui()   { printf 'ui_print %s\nui_print\n' "$1" >&"$OUTFD"; }
prog() { printf 'progress %s %s\n' "$1" "$2" >&"$OUTFD"; }

SUPER=/dev/block/by-name/super
TMP=/tmp/payload
THREADS=14
RESERVED=4194304

now()  { date +%s; }
secs() { echo $(( $2 - $1 )); }
fail() { ui "     [FAILED] $1"; ui ">>>>> Installation aborted <<<<<"; exit 1; }

hrsize() {
    awk -v b="$1" 'BEGIN {
        if (b >= 1073741824) printf "%.1f GB", b/1073741824
        else if (b >= 1048576) printf "%.1f MB", b/1048576
        else if (b >= 1024) printf "%.1f KB", b/1024
        else printf "%d B", b
    }'
}

tmpfree_val() {
    F=$(df -k $TMP 2>/dev/null | awk 'NR==2{print $4}')
    if [ -n "$F" ]; then
        if [ "$F" -ge 1048576 ]; then
            echo "$(expr $F / 1048576) GB"
        else
            echo "$(expr $F / 1024) MB"
        fi
    else
        echo "unknown"
    fi
}

zipname() { echo "$1" | awk -F/ '{print $NF}'; }

[ -z "$PKG" ] && { echo "Usage: $0 <ota.zip> [outfd]"; exit 1; }
[ ! -f "$PKG" ] && fail "Package not found: $PKG"
# ---- Check package format ----
if ! unzip -l "$PKG" 2>/dev/null | grep -q 'payload\.bin'; then
    ui "===================================="
    ui ">>>>> Non-payload package <<<<<"
    ui "===================================="
    exit 1
fi

[ ! -b "$SUPER" ] && fail "super partition not found"
T0=$(now)

STATIC_PARTITIONS="
init_boot
recovery
boot
abl
"
SELECT_TIMEOUT=10

static_is_selectable() {
    [ -z "$1" ] && return 1
    _sp="$1"
    for _cfg in $STATIC_PARTITIONS; do
        [ -z "$_cfg" ] && continue
        [ "$_cfg" = "$_sp" ] && return 0
    done
    return 1
}

static_should_skip() {
    _q="$1"
    [ -z "$_q" ] && return 1
    _v=$(awk -F'|' -v p="$_q" '$1==p{print $2;exit}' "$TMP/static_select.txt" 2>/dev/null)
    [ "$_v" = "skip" ]
}

sel_set_state() {
    _want="$1"
    _new="$2"
    _n=0
    : > "$TMP/static_select.tmp"
    while IFS= read -r _l; do
        _n=$((_n + 1))
        _nm=$(echo "$_l" | cut -d'|' -f1)
        if [ "$_n" -eq "$_want" ]; then
            echo "$_nm|$_new" >> "$TMP/static_select.tmp"
        else
            echo "$_l" >> "$TMP/static_select.tmp"
        fi
    done < "$TMP/static_select.txt"
    mv "$TMP/static_select.tmp" "$TMP/static_select.txt"
}

sel_set_all_flash() {
    : > "$TMP/static_select.tmp"
    while IFS= read -r _l; do
        _nm=$(echo "$_l" | cut -d'|' -f1)
        echo "$_nm|flash" >> "$TMP/static_select.tmp"
    done < "$TMP/static_select.txt"
    mv "$TMP/static_select.tmp" "$TMP/static_select.txt"
}

static_selection() {
    _sel="$TMP/static_select.txt"
    : > "$_sel"

    while read _name _sz _h; do
        [ -z "$_name" ] && continue
        if static_is_selectable "$_name"; then
            echo "$_name|flash" >> "$_sel"
        fi
    done < "$TMP/static.txt"

    _count=$(wc -l < "$_sel")
    [ "$_count" -le 0 ] && return 0

    ui ">>>>> Physical Partition Selection <<<<<"
    ui "     [Volume+] Switch    [Volume-] Confirm"
    ui "     [Power] Ignore"
    ui "     No action for ${SELECT_TIMEOUT} seconds = flash all"

    _idx=1
    _start=$(now)
    _cur_name=""
    _cur_state=""

    show_cur() {
        _line=$(head -n "$_idx" "$TMP/static_select.txt" | tail -n 1)
        _cur_name=$(echo "$_line" | cut -d'|' -f1)
        _cur_state=$(echo "$_line" | cut -d'|' -f2)

        if [ "$_cur_state" = "skip" ]; then
            _disp="skip"
        else
            _disp="flash"
        fi
        ui "     [$_idx/$_count]    $_cur_name    [$_disp]"
    }

    show_cur

    while [ "$_idx" -le "$_count" ]; do
        _now=$(now)
        _elapsed=$(( _now - _start ))
        if [ "$_elapsed" -ge "$SELECT_TIMEOUT" ]; then
            ui "     [Timeout] Flashing all physical partitions"
            sel_set_all_flash
            return 0
        fi

        _event=$(timeout 1 getevent -qlc 1 2>/dev/null)
        [ -z "$_event" ] && continue

        _handled_key=""

        case "$_event" in
            *KEY_VOLUMEUP*DOWN*)
                _handled_key=KEY_VOLUMEUP
                if [ "$_cur_state" = "skip" ]; then
                    _new=flash
                    _disp="flash"
                else
                    _new=skip
                    _disp="skip"
                fi
                sel_set_state "$_idx" "$_new"
                _cur_state="$_new"
                ui "     [Switched]    $_cur_name    [$_disp]"
                ;;
            *KEY_VOLUMEDOWN*DOWN*)
                _handled_key=KEY_VOLUMEDOWN
                _idx=$(( _idx + 1 ))
                if [ "$_idx" -le "$_count" ]; then
                    show_cur
                else
                    ui "     [Confirmed] Physical partition selection"
                    return 0
                fi
                ;;
            *KEY_POWER*DOWN*)
                _handled_key=KEY_POWER
                ;;
        esac

        if [ -n "$_handled_key" ]; then
            while :; do
                _release=$(timeout 1 getevent -qlc 1 2>/dev/null)
                [ -z "$_release" ] && break
                case "$_release" in
                    *"$_handled_key"*UP*) break ;;
                esac
            done
        fi
    done

    ui "     [Confirmed] Physical partition selection"
}

ui "===================================="
ui ">>>>> Target Slot Selection <<<<<"
ui "===================================="
CUR=$(bootctl get-current-slot 2>/dev/null)
case "$CUR" in
    0) DEF=_b; ui "     Current slot: [_a]" ;;
    1) DEF=_a; ui "     Current slot: [_b]" ;;
    *) DEF=_a; ui "     Current slot: [unknown]" ;;
esac

SLOT=$DEF
ui "     Default target:  [$DEF]"
ui "------------------------------------"
ui "     [Volume+] Switch    [Volume-] Confirm"
ui "     [Note] 10 seconds of inactivity = default"
ui "------------------------------------"

_tsel_start=$(now)
_tsel_sel=0
_last_shown=""
while :; do
    if [ "$_tsel_sel" = "0" ]; then
        _cur_target=$DEF
        _tag="default"
    else
        _cur_target=$SLOT
        _tag="selected"
    fi

    if [ "$_last_shown" != "$_cur_target" ]; then
        ui "     [$_tag] Flash target = [$_cur_target]"
        _last_shown="$_cur_target"
    fi

    _tsel_now=$(now)
    if [ $(( _tsel_now - _tsel_start )) -ge 10 ]; then
        SLOT=$DEF
        OTHER=$( [ "$SLOT" = "_a" ] && echo "_b" || echo "_a" )
        ui "     [Timeout] Flash target = [$SLOT]"
        break
    fi

    _ev=$(timeout 1 getevent -qlc 1 2>/dev/null)
    [ -z "$_ev" ] && continue

    case "$_ev" in
        *KEY_VOLUMEUP*DOWN*)
            if [ "$SLOT" = "_a" ]; then
                SLOT=_b
            else
                SLOT=_a
            fi
            _tsel_sel=1
            _last_shown=""
            while :; do
                _r=$(timeout 1 getevent -qlc 1 2>/dev/null)
                [ -z "$_r" ] && break
                case "$_r" in *KEY_VOLUMEUP*UP*) break ;; esac
            done
            ;;
        *KEY_VOLUMEDOWN*DOWN*)
            if [ "$_tsel_sel" = "0" ]; then
                SLOT=$DEF
            fi
            OTHER=$( [ "$SLOT" = "_a" ] && echo "_b" || echo "_a" )
            ui "     [Confirmed] Flash target = [$SLOT]"
            while :; do
                _r=$(timeout 1 getevent -qlc 1 2>/dev/null)
                [ -z "$_r" ] && break
                case "$_r" in *KEY_VOLUMEDOWN*UP*) break ;; esac
            done
            break
            ;;
    esac
done

if [ -z "$OTHER" ]; then
    OTHER=$( [ "$SLOT" = "_a" ] && echo "_b" || echo "_a" )
fi

ui "===================================="
prog 0.01 5


rm -rf $TMP
mkdir -p $TMP || fail "Cannot create $TMP"
ui "     [Temp] Free space $(tmpfree_val)"

ui ">>>>> Parsing OTA package <<<<<"
PINFO=$TMP/pinfo.txt
payload_extract -i "$PKG" -p > "$PINFO" 2>&1 || fail "payload_extract -p failed"
[ -s "$PINFO" ] || fail "payload info is empty"

GROUP=$(awk '/^DynamicPartition:/{f=1;next} f&&/name:/{print $2;exit}' "$PINFO")
DYN=$(awk '/^DynamicPartition:/{f=1;next} f&&/items:/{gsub(/.*\[|\].*/,"");gsub(/[",]/," ");print;exit}' "$PINFO")
[ -z "$GROUP" ] && fail "Dynamic partition group not found"
[ -z "$DYN" ] && fail "Dynamic partition list is empty"
ui "     [Group] $GROUP"

awk '
    $1=="name:" {
        name=$2; size=$4; hash=$6;
        if (name != "" && size != "" && hash != "") {
            print name, size, hash;
        }
    }
' "$PINFO" > $TMP/parts.txt

while read p sz h; do
    [ -z "$p" ] && continue
    for d in $DYN; do
        [ "$p" = "$d" ] || continue
        eval "SZ_$p=$sz"; eval "H_$p=$h"
    done
done < $TMP/parts.txt

: > $TMP/static.txt
while read p sz h; do
    [ -z "$p" ] && continue
    isd=0
    for d in $DYN; do [ "$p" = "$d" ] && { isd=1; break; }; done
    [ "$isd" = "0" ] && echo "$p $sz $h" >> $TMP/static.txt
done < $TMP/parts.txt

STATIC=$(awk 'NF>0 {print $1}' $TMP/static.txt)

IS_OPLUS=0
for p in $DYN; do [ "$p" = "my_stock" ] && IS_OPLUS=1; done
if [ "$IS_OPLUS" = "1" ]; then
    for p in my_company my_preload; do
        bin_path="/system/bin/$p.img"
        if [ ! -s "$bin_path" ]; then
            bin_path="/tmp/tools/$p.img"
        fi
        if [ -s "$bin_path" ]; then
            sz=$(wc -c < "$bin_path")
            h=$(sha256sum "$bin_path" | awk '{print $1}')
            eval "SZ_$p=$sz"; eval "H_$p=$h"
            DYN="$DYN $p"
            echo "$p $sz $h" >> $TMP/parts.txt
            ui "     [Loaded] $p from $bin_path"
        else
            ui "     [Missing] $p skipped"
        fi
    done
fi

DYN_COUNT=$(echo $DYN | wc -w)
STATIC_COUNT=$(echo $STATIC | wc -w)
ui "     [Dynamic] $DYN_COUNT partitions"
ui "     [Physical]  $STATIC_COUNT partitions"
prog 0.05 5

ui ">>>>> Building Super metadata <<<<<"
SUPERSIZE=$(blockdev --getsize64 $SUPER 2>/dev/null)
[ -z "$SUPERSIZE" ] && fail "Cannot read super partition size"
GSIZE=$(expr $SUPERSIZE - $RESERVED)

SG="${GROUP}${SLOT}"
OG="${GROUP}${OTHER}"

LP="--metadata-size 65536 --super-name super --virtual-ab --block-size 4096"
LP="$LP --device-size $SUPERSIZE --metadata-slots 3"
LP="$LP --group ${SG}:$GSIZE --group ${OG}:$GSIZE"
for p in $DYN; do
    eval sz=\$SZ_$p
    LP="$LP --partition ${p}${SLOT}:readonly:$sz:${SG}"
    LP="$LP --partition ${p}${OTHER}:readonly:0:${OG}"
done

lpmake $LP --output $TMP/meta.img > $TMP/lpmake.log 2>&1
RC=$?
[ $RC -ne 0 ] && { while IFS= read -r l; do ui "     [lpmake] $l"; done < $TMP/lpmake.log; fail "lpmake"; }
ui "     [OK] meta.img written  $(wc -c < $TMP/meta.img) bytes"

mlpdump $TMP/meta.img > $TMP/lp.txt 2>&1
[ -s $TMP/lp.txt ] || fail "Cannot read meta.img"
awk '/^  Name: /{n=$2} /linear super/{print n, $NF}' $TMP/lp.txt > $TMP/off.txt
[ -s $TMP/off.txt ] || fail "No offsets found"

ui ">>>>> Flashing dynamic partitions <<<<<"
DI=0
for p in $DYN; do
    DI=$((DI+1))
    tn="${p}${SLOT}"
    off=$(awk -v t="$tn" '$1==t{print $2}' $TMP/off.txt)
    [ -z "$off" ] && fail "$tn has no offset"

    ui "     [$DI/$DYN_COUNT]    $tn"

    case "$p" in
        my_company|my_preload)
            src=/system/bin/$p.img
            [ ! -s "$src" ] && src=/tmp/tools/$p.img
            [ ! -s "$src" ] && fail "$p missing"
            ;;
        *)
            src=$TMP/$p.img
            rm -f "$src"
            payload_extract -i "$PKG" -o "$TMP" -X "$p" -T"$THREADS" > /dev/null 2>&1
            [ $? -ne 0 ] && fail "$p extraction failed"
            [ ! -f "$src" ] && [ -f "$TMP/payload/$p.img" ] && mv "$TMP/payload/$p.img" "$src"
            [ ! -s "$src" ] && fail "$p image not found"
            ;;
    esac

    fsz=$(wc -c < "$src")
    ui "     [Extracted] $p    $(hrsize $fsz)"
    ui "     [Flashing]  $tn    offset $off"

    seek=$(expr $off \* 512)
    dd if="$src" of="$SUPER" bs=4M oflag=seek_bytes seek=$seek conv=notrunc > /dev/null 2>&1
    RC=$?
    sync
    [ $RC -ne 0 ] && fail "$p write failed"
    ui "     [Written]     $tn    [OK]"

    case "$p" in
        my_company|my_preload) ;;
        *) rm -f "$src" ;;
    esac
    prog 0.$(printf "%02d" $((10 + DI*55/DYN_COUNT))) 1
done

ui ">>>>> Flashing physical partitions <<<<<"
static_selection

STATIC_FLASH=""
for _sp in $STATIC; do
    [ -z "$_sp" ] && continue
    if static_should_skip "$_sp"; then
        ui "     [Skipped]  $_sp"
    else
        STATIC_FLASH="$STATIC_FLASH $_sp"
    fi
done
STATIC_FLASH=$(echo "$STATIC_FLASH")

if [ -n "$STATIC_FLASH" ]; then
    ui "     [Extracting] selected physical images"
    static_csv=$(echo "$STATIC_FLASH" | tr ' ' ',')
    payload_extract -i "$PKG" -o "$TMP" -X "$static_csv" -T"$THREADS" > /dev/null 2>&1
    RC=$?
    [ $RC -ne 0 ] && fail "Physical image extraction failed"
    ui "     [Extracted]  selected physical images"
else
    ui "     [Skipped]    all optional physical partitions"
fi
ui "     [Temp] Free space $(tmpfree_val)"

SI=0
while read p sz h; do
    [ -z "$p" ] && continue
    SI=$((SI+1))
    if static_should_skip "$p"; then
        ui "     [$SI/$STATIC_COUNT]    $p    [Skipped]"
        continue
    fi

    dev=/dev/block/by-name/${p}${SLOT}
    [ ! -e "$dev" ] && dev=/dev/block/by-name/$p
    if [ ! -e "$dev" ]; then
        ui "     [$SI/$STATIC_COUNT]    $p    [No device]"
        continue
    fi

    src=$TMP/$p.img
    [ ! -f "$src" ] && [ -f "$TMP/payload/$p.img" ] && mv "$TMP/payload/$p.img" "$src"
    [ ! -s "$src" ] && fail "$p image not found"

    fsz=$(wc -c < "$src")
    ui "     [$SI/$STATIC_COUNT]    $p    $(hrsize $fsz)"

    if [ -n "$h" ] && [ "$h" != "-" ]; then
        ah=$(sha256sum "$src" | awk '{print $1}')
        [ "$ah" != "$h" ] && fail "$p source file sha256 mismatch"
    fi

    dd if="$src" of="$dev" bs=4M conv=fsync > /dev/null 2>&1
    RC=$?
    sync
    [ $RC -ne 0 ] && fail "$p write failed"

    rb=$TMP/rb
    rm -f $rb
    cnt=$(expr $fsz / 4194304 + 1)
    dd if="$dev" of=$rb bs=4M count=$cnt > /dev/null 2>&1
    truncate -s $fsz $rb 2>/dev/null
    rh=$(sha256sum $rb | awk '{print $1}')
    rm -f $rb

    if [ -n "$h" ] && [ "$h" != "-" ]; then
        [ "$rh" != "$h" ] && fail "$p readback sha256 mismatch"
        ui "     [Written]     $p    [OK]    verified"
    else
        ui "     [Written]     $p    [OK]"
    fi

    rm -f "$src"
    prog 0.$(printf "%02d" $((65 + SI*28/STATIC_COUNT))) 1
done < $TMP/static.txt

ui ">>>>> Committing Super metadata <<<<<"
lpflash "$SUPER" $TMP/meta.img
RC=$?
sync
[ $RC -ne 0 ] && fail "lpflash failed"
ui "     [lpflash]   applied"

mlpdump $SUPER > $TMP/final.txt 2>&1
for p in $DYN; do
    grep -q "Name: ${p}${SLOT}" $TMP/final.txt || fail "Metadata missing ${p}${SLOT}"
done
ui "     [Verified]    metadata    [OK]"
prog 0.95 1

ui ">>>>> Setting active slot <<<<<"
case "$SLOT" in
    _a) bootctl set-active-boot-slot 0 ;;
    _b) bootctl set-active-boot-slot 1 ;;
esac
[ $? -ne 0 ] && fail "bootctl failed"
ui "     [Slot]      active slot set to $SLOT"
prog 0.97 1

rm -rf $TMP
rm -rf /tmp/tools
TT=$(secs $T0 $(now))
ui ">>>>> Success <<<<<"
ui "     Slot $SLOT    Time ${TT}s"
ui "     $(zipname "$PKG")"
prog 1.0 1
exit 0