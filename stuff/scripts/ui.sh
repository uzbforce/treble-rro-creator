#!/usr/bin/env bash
# =============================================================================
# ui.sh — how a terminal report is drawn
# =============================================================================
# Sourced by common.sh (so the menu and build.sh get it) and by the probes that
# print a report. Never run directly.
#
# The reports used to be fixed-width printf columns, which is the right shape on
# a 100-column desktop window and unreadable on a phone: 58-column rules wrapped
# mid-border, and a line of prose about a property ran off the edge and came
# back as a second, unrelated-looking line. Everything here is measured against
# the real window instead, and long prose is wrapped with a hanging indent so a
# wrapped paragraph still looks like one item.
#
# Three switches, all optional:
#   UI_COLOR=always|never|auto   auto (the default) is "a terminal is attached"
#   UI_COLS=N                    the width to draw for, when there is no tty
#   UI_ASCII=1                   ASCII borders and glyphs, for a font or a
#                                codepage that cannot show ─ │ · ⚠
# Colour is off when stdout is not a terminal, so `./build.sh | tee log` and the
# JSON probes stay clean, and NO_COLOR is respected.

# ---------------------------------------------------------------------------
# Width
# ---------------------------------------------------------------------------
# A phone terminal is 40-50 columns, a desktop window is often 200. Below 40
# nothing lines up; above 100 an eye loses the start of the line on the way
# back, so the drawing width is clamped and the spare columns stay empty.
ui_cols() {
    local c="${UI_COLS:-}"
    [ -n "$c" ] || c="${COLUMNS:-}"
    if [ -z "$c" ] && [ -t 1 ] && command -v tput >/dev/null 2>&1; then
        c="$(tput cols 2>/dev/null || true)"
    fi
    case "$c" in ''|*[!0-9]*) c=80 ;; esac
    [ "$c" -ge 40 ] || c=40
    [ "$c" -le 100 ] || c=100
    printf '%s' "$c"
}

# ---------------------------------------------------------------------------
# Palette and glyphs
# ---------------------------------------------------------------------------
# Assigned once, at source time, so a report never has to ask twice.
ui_wants_color() {
    case "${UI_COLOR:-auto}" in
        always) return 0 ;;
        never) return 1 ;;
    esac
    [ -z "${NO_COLOR:-}" ] || return 1
    [ "${TERM:-}" != dumb ] || return 1
    [ -t 1 ]
}

if ui_wants_color; then
    UI_RED=$'\033[31m'; UI_GREEN=$'\033[32m'; UI_YELLOW=$'\033[33m'
    UI_BLUE=$'\033[36m'; UI_MAGENTA=$'\033[35m'
    UI_BOLD=$'\033[1m'; UI_DIM=$'\033[2m'; UI_OFF=$'\033[0m'
else
    UI_RED=''; UI_GREEN=''; UI_YELLOW=''; UI_BLUE=''; UI_MAGENTA=''
    UI_BOLD=''; UI_DIM=''; UI_OFF=''
fi

# The box and the glyphs are decoration, so a terminal that cannot show them
# gets plain ASCII rather than a row of question marks.
if [ "${UI_ASCII:-0}" = "1" ] || [ "${UI_ASCII:-0}" = "true" ]; then
    UI_TL='+'; UI_TR='+'; UI_BL='+'; UI_BR='+'; UI_H='-'; UI_V='|'
    UI_TICK='+'; UI_CROSS='x'; UI_WARN='!'; UI_DOT='-'
    UI_BAR_ON='#'; UI_BAR_OFF='-'
else
    UI_TL='┌'; UI_TR='┐'; UI_BL='└'; UI_BR='┘'; UI_H='─'; UI_V='│'
    UI_TICK='✓'; UI_CROSS='✗'; UI_WARN='⚠'; UI_DOT='·'
    UI_BAR_ON='█'; UI_BAR_OFF='░'
fi

# ---------------------------------------------------------------------------
# Prose
# ---------------------------------------------------------------------------
# ui_repeat N STRING — STRING thirty times. Built by hand because printf's %*s
# pads by bytes, and a box-drawing character is three of them.
ui_repeat() {
    local n="$1" s="$2" out=""
    while [ "$n" -gt 0 ]; do
        out="$out$s"
        n=$((n - 1))
    done
    printf '%s' "$out"
}

# ui_fit TEXT WIDTH — TEXT cut to WIDTH, ending in an ellipsis when it was cut.
# A value that no longer fits is better shortened than pushed out of its column.
ui_fit() {
    local text="$1" width="$2"
    [ "$width" -ge 1 ] || { printf ''; return 0; }
    if [ "${#text}" -le "$width" ]; then
        printf '%s' "$text"
    else
        printf '%s…' "${text:0:$((width - 1))}"
    fi
}

# ui_wrap TEXT INDENT [AVAIL] — greedy word wrap, every line starting at INDENT.
# Used for the one sentence in a report that explains itself: at 40 columns it
# is three short lines instead of one that runs off the edge.
ui_wrap() {
    local text="$1" indent="${2:-0}" avail="${3:-}" pad
    [ -n "$text" ] || return 0
    [ -n "$avail" ] || avail=$(( $(ui_cols) - indent ))
    [ "$avail" -ge 8 ] || avail=8
    pad="$(ui_repeat "$indent" ' ')"
    printf '%s' "$text" | awk -v w="$avail" -v pad="$pad" '
        {
            line = ""
            n = split($0, word, " ")
            for (i = 1; i <= n; i++) {
                ww = word[i]
                if (ww == "") continue
                # A path is one long word and would run past the edge of a
                # phone; break it rather than let the line wrap by itself, and
                # break after a separator when there is one, so the pieces stay
                # readable (persist.sys.overlay. / zephyr, not zephy / r).
                while (length(ww) > w) {
                    if (line != "") { print pad line; line = "" }
                    cut = w
                    for (j = w; j > w / 2; j--) {
                        ch = substr(ww, j, 1)
                        if (ch == "/" || ch == "." || ch == "-" || ch == "_" || ch == "=" || ch == ",") { cut = j; break }
                    }
                    print pad substr(ww, 1, cut)
                    ww = substr(ww, cut + 1)
                }
                if (ww == "") continue
                if (line == "") line = ww
                else if (length(line) + 1 + length(ww) <= w) line = line " " ww
                else { print pad line; line = ww }
            }
            if (line != "") print pad line
        }
    '
}

# ---------------------------------------------------------------------------
# Blocks
# ---------------------------------------------------------------------------
# ui_heading TEXT — a section title with a rule under it, sized to the window.
ui_heading() {
    local w; w=$(ui_cols)
    printf '\n  %s%s%s\n' "$UI_BOLD" "$1" "$UI_OFF"
    printf '  %s%s%s\n' "$UI_DIM" "$(ui_repeat $((w - 3)) "$UI_H")" "$UI_OFF"
}

# ui_rule [INDENT] — a plain separator.
ui_rule() {
    local indent="${1:-2}" w; w=$(ui_cols)
    # One short of the window, like ui_heading: a rule that ends in the last
    # column wraps on a terminal that is exactly that wide.
    printf '%s%s%s%s\n' "$(ui_repeat "$indent" ' ')" "$UI_DIM" \
        "$(ui_repeat $((w - indent - 1)) "$UI_H")" "$UI_OFF"
}

# ui_kv KEY VALUE [KEYWIDTH] — one aligned key and its value.
# A value wider than the window (a property name, a path) moves under its key
# and wraps there, instead of running off the edge of a phone.
ui_kv() {
    local key="$1" value="$2" keyw="${3:-10}" pad cols line
    cols=$(ui_cols)
    printf -v pad '%*s' $((keyw - ${#key})) ''
    if [ $(( 3 + keyw + ${#value} )) -lt "$cols" ]; then
        printf '  %s%s%s  %s\n' "$UI_DIM" "$key$pad" "$UI_OFF" "$value"
        return 0
    fi
    printf '  %s%s%s\n' "$UI_DIM" "$key" "$UI_OFF"
    ui_wrap "$value" 4 | while IFS= read -r line; do
        printf '%s%s%s\n' "$UI_BOLD" "$line" "$UI_OFF"
    done
}

# ui_pad TEXT WIDTH — TEXT followed by spaces up to WIDTH characters.
#
# printf's %-*s pads by bytes, so one `·` (three bytes) would leave a row three
# columns short and the right border would step in once per glyph. Everything a
# user typed — a model name, a path, a dotted list — goes through here.
ui_pad() {
    local text="$1" width="$2" pad=""
    [ "${#text}" -lt "$width" ] && printf -v pad '%*s' $((width - ${#text})) ''
    printf '%s%s' "$text" "$pad"
}

# ui_panel_line CONTENT INNER — CONTENT padded to INNER and closed off with the
# right border. CONTENT carries its own leading space, so the row never starts
# hard against the border.
ui_panel_line() {
    local content="$1" inner="$2" pad=""
    [ "${#content}" -lt "$inner" ] && printf -v pad '%*s' $((inner - ${#content})) ''
    printf '  %s%s%s%s%s%s%s%s\n' "$UI_DIM" "$UI_V" "$UI_OFF" "$content" "$pad" \
        "$UI_DIM" "$UI_V" "$UI_OFF"
}

# ui_panel_row KEY VALUE KEYWIDTH INNER — one key/value row.
# A value too long for the row is wrapped onto its own indented lines rather than
# cut with an ellipsis: half a property name is worse than two lines.
ui_panel_row() {
    local key="$1" value="$2" keyw="$3" inner="$4" keypad="" line avail
    local -a parts=()
    printf -v keypad '%*s' $((keyw - ${#key})) ''
    avail=$((inner - keyw - 3))
    # Strictly less than: a value that exactly fills the row has no space left
    # before the border, which reads as a clipped cell.
    if [ ${#value} -lt "$avail" ]; then
        ui_panel_line " $key$keypad  $value" "$inner"
        return 0
    fi
    # Too wide: wrap it, but keep the first piece on the key's own line so the
    # two still read as one row rather than a label with a paragraph under it.
    # One column narrower than the row: the last character must not touch the
    # border, or the value reads as clipped.
    while IFS= read -r die; do parts+=("$die"); done < <(ui_wrap "$value" 0 $((avail - 1)))
    ui_panel_line " $key$keypad  ${parts[0]:-}" "$inner"
    local i
    for ((i = 1; i < ${#parts[@]}; i++)); do
        line="$(ui_repeat $((keyw + 3)) ' ')${parts[$i]}"
        ui_panel_line "$line" "$inner"
    done
}

# ui_panel TITLE "KEY|VALUE" ... — a titled box holding aligned pairs.
#
# One call rather than open/row/close because the box has to know its widest key
# before the top border can be drawn, and that is only known once every row has
# been seen.
ui_panel() {
    local title="$1"; shift
    local inner keyw=0 row key bar
    local -a keys=() values=()
    # inner is the width between the two vertical borders. Borders plus the two
    # columns of left margin are kept off the right edge, where a terminal likes
    # to wrap on the last character.
    inner=$(( $(ui_cols) - 4 ))
    printf '\n'
    for row in "$@"; do
        key="${row%%|*}"
        [ "${#key}" -gt "$keyw" ] && keyw=${#key}
    done
    [ "$keyw" -le 12 ] || keyw=12
    for row in "$@"; do
        keys+=("${row%%|*}")
        values+=("${row#*|}")
    done
    # A title longer than the box would draw a negative rule; shorten it instead.
    title="$(ui_fit "$title" $((inner - 6)))"
    bar=$(ui_repeat $((inner - ${#title} - 3)) "$UI_H")
    printf '  %s%s%s %s%s%s %s%s%s\n' "$UI_DIM" "$UI_TL" "$UI_H" \
        "$UI_BOLD" "$title" "$UI_OFF" "$UI_DIM" "$bar" "$UI_TR$UI_OFF"
    for i in "${!keys[@]}"; do
        ui_panel_row "${keys[$i]}" "${values[$i]}" "$keyw" "$inner"
    done
    printf '  %s%s%s%s\n' "$UI_DIM" "$UI_BL" "$(ui_repeat "$inner" "$UI_H")" "$UI_BR$UI_OFF"
}

# ui_meter VALUE MAX [WIDTH] — a filled bar whose colour is the verdict.
# Green is "this is the one", red is "do not".
ui_meter() {
    local value="$1" max="$2" width="${3:-10}" on off color
    case "$max" in ''|*[!0-9]*) max=1 ;; esac
    [ "$max" -gt 0 ] || max=1
    on=$((value * width / max))
    [ "$on" -gt "$width" ] && on="$width"
    [ "$on" -lt 0 ] && on=0
    off=$((width - on))
    if [ "$value" -ge 100 ]; then color="$UI_GREEN"
    elif [ "$value" -ge 60 ]; then color="$UI_YELLOW"
    else color="$UI_RED"
    fi
    printf '%s%s%s%s%s' "$color" "$(ui_repeat "$on" "$UI_BAR_ON")" \
        "$UI_DIM" "$(ui_repeat "$off" "$UI_BAR_OFF")" "$UI_OFF"
}

# ui_mark ok|warn|bad|note "TEXT" [INDENT] — a glyph, prose wrapped under it.
# INDENT (default 2) is the column of the glyph; the text starts two columns
# later and every wrapped line is drawn at that same column.
ui_mark() {
    local kind="$1" text="$2" indent="${3:-2}" glyph color line first=1 pad
    case "$kind" in
        ok)   glyph="$UI_TICK";  color="$UI_GREEN" ;;
        warn) glyph="$UI_WARN";  color="$UI_YELLOW" ;;
        bad)  glyph="$UI_CROSS"; color="$UI_RED" ;;
        *)    glyph="$UI_DOT";   color="$UI_DIM" ;;
    esac
    printf -v pad '%*s' $((indent + 2)) ''
    ui_wrap "$text" $((indent + 2)) | while IFS= read -r line; do
        if [ "$first" = 1 ]; then
            printf '%*s%s%s%s %s\n' "$indent" '' "$color" "$glyph" "$UI_OFF" "${line#"$pad"}"
            first=0
        else
            printf '%s\n' "$line"
        fi
    done
}

# ui_item NUM LABEL [DETAIL] — one row of a menu or an option list.
#
#   `   1  Auto Detect   cutout, corners, refresh rate, VoLTE, 5G`
#
# The number is the accent colour, the label bold and the description dim, so
# the eye follows the label column and can still find a number at a glance. On a
# phone the description does not fit beside the label, so it moves to its own
# indented, wrapped line instead of being cut off at the edge.
ui_item() {
    local num="$1" label="$2" detail="${3:-}" lw="${4:-${#2}}" cols head line
    cols=$(ui_cols)
    # A label wider than the column (a long section title) widens the column
    # rather than being cut or pushing the description out of line.
    [ "$lw" -ge "${#label}" ] || lw=${#label}
    head="  $(printf '%3s' "$num")  "
    # A label longer than the window is a section header somewhere in config.env
    # — `Overlay repo submission (Doze-off, submission only)` — and it runs off a
    # phone. It wraps under the number, and the description follows it there.
    # The head is 2 spaces, three for the number and two after it: seven.
    if [ $(( 7 + ${#label} )) -ge "$cols" ]; then
        printf '  %s%3s%s\n' "$UI_BLUE" "$num" "$UI_OFF"
        ui_wrap "$label" 7 $((cols - 8)) | while IFS= read -r line; do
            printf '%s%s%s\n' "$UI_BOLD" "$line" "$UI_OFF"
        done
        [ -n "$detail" ] || return 0
        ui_wrap "$detail" 9 $((cols - 10)) | while IFS= read -r line; do
            printf '%s%s%s\n' "$UI_DIM" "$line" "$UI_OFF"
        done
        return 0
    fi
    printf '%s%s%s%s%s' "$UI_BLUE" "$head" "$UI_OFF" "$UI_BOLD" "$label"
    if [ -z "$detail" ]; then
        printf '%s\n' "$UI_OFF"
        return 0
    fi
    # 7 for the number column and its gaps, 2 between label and description.
    if [ $(( 7 + lw + 2 + ${#detail} )) -le "$cols" ]; then
        printf '%s%*s  %s%s%s\n' "$UI_OFF" $((lw - ${#label})) '' \
            "$UI_DIM" "$detail" "$UI_OFF"
        return 0
    fi
    printf '%s\n' "$UI_OFF"
    ui_wrap "$detail" 7 $((cols - 8)) | while IFS= read -r line; do
        printf '%s%s%s\n' "$UI_DIM" "$line" "$UI_OFF"
    done
}

# ui_trust_color high|medium|low — green for an answer, red for a gamble.
# The trust word is the one thing a reader scans a ranked list for, so it is
# coloured rather than left in the same grey as the rest of the meta line.
ui_trust_color() {
    case "${1:-}" in
        high) printf '%s' "$UI_GREEN" ;;
        medium) printf '%s' "$UI_YELLOW" ;;
        low|*) printf '%s' "$UI_RED" ;;
    esac
}

# ui_split TEXT SEP — TEXT split on SEP, one element per field, in UI_SPLIT.
ui_split() {
    local item
    UI_SPLIT=()
    while IFS= read -r item; do
        UI_SPLIT+=("$item")
    done < <(printf '%s\n' "$1" | tr "$2" '\n')
}

# ui_table "COL|COL|COL" "CELL|CELL|CELL" ... — an aligned table, or, when the
# columns would not fit the window, one block per row.
#
# Cutting a table in half is worse than folding it: below the width where the
# natural columns collide, every row becomes its own two-line entry — the key in
# bold and the rest joined with a dot — which is the same data, stacked, and
# still comparable down the page.
ui_table() {
    local header="$1"; shift
    local avail ncols=0 i k w total cell line first
    local -a rows=("$@") heads=() widths=()
    avail=$(( $(ui_cols) - 4 ))
    ui_split "$header" '|'
    heads=("${UI_SPLIT[@]}")
    ncols=${#heads[@]}
    for k in "${!heads[@]}"; do widths[$k]=${#heads[$k]}; done
    for i in "${!rows[@]}"; do
        ui_split "${rows[$i]}" '|'
        for k in "${!UI_SPLIT[@]}"; do
            [ "$k" -lt "$ncols" ] || continue
            cell="${UI_SPLIT[$k]}"
            [ "${#cell}" -gt "${widths[$k]}" ] && widths[$k]=${#cell}
        done
    done
    total=$(( 2 * (ncols - 1) ))
    for w in "${widths[@]}"; do total=$(( total + w )); done

    if [ "$total" -gt "$avail" ]; then
        for i in "${!rows[@]}"; do
            ui_split "${rows[$i]}" '|'
            # A size or a zone on its own line means nothing without the column
            # it came from, so the header word leads it: `Size 12K`.
            printf '\n  %s%s%s %s%s%s\n' "$UI_DIM" "${heads[0]}" "$UI_OFF" \
                "$UI_BOLD" "${UI_SPLIT[0]}" "$UI_OFF"
            line=""
            for ((k = 1; k < ncols; k++)); do
                cell="${UI_SPLIT[$k]:-}"
                [ -n "$cell" ] || continue
                if [ -z "$line" ]; then line="$cell"; else line="$line $UI_DOT $cell"; fi
            done
            [ -n "$line" ] || continue
            ui_wrap "$line" 4 | while IFS= read -r cell; do
                printf '%s%s%s\n' "$UI_DIM" "$cell" "$UI_OFF"
            done
        done
        return 0
    fi

    # Every column but the last is padded; the last one is printed as it is, so
    # a table does not leave a trail of spaces a terminal will happily select.
    printf '\n  %s' "$UI_BOLD"
    for k in "${!heads[@]}"; do
        if [ "$k" -lt $((ncols - 1)) ]; then
            printf '%-*s  ' "${widths[$k]}" "${heads[$k]}"
        else
            printf '%s' "${heads[$k]}"
        fi
    done
    printf '%s\n' "$UI_OFF"
    printf '  %s%s%s\n' "$UI_DIM" "$(ui_repeat "$total" "$UI_H")" "$UI_OFF"
    for i in "${!rows[@]}"; do
        ui_split "${rows[$i]}" '|'
        printf '  %s' "$UI_DIM"
        printf '%-*s' "${widths[0]}" "${UI_SPLIT[0]}"
        printf '%s  ' "$UI_OFF"
        for ((k = 1; k < ncols; k++)); do
            if [ "$k" -lt $((ncols - 1)) ]; then
                printf '%-*s  ' "${widths[$k]}" "${UI_SPLIT[$k]:-}"
            else
                printf '%s' "${UI_SPLIT[$k]:-}"
            fi
        done
        printf '\n'
    done
}

# ui_title "TEXT" [SUBTITLE] — the first line of a report, ruled to the width.
ui_title() {
    local w; w=$(ui_cols)
    printf '\n  %s%s%s\n' "$UI_BOLD" "$1" "$UI_OFF"
    if [ -n "${2:-}" ]; then
        ui_wrap "$2" 2 $((w - 2)) | while IFS= read -r line; do
            printf '%s%s%s\n' "$UI_DIM" "$line" "$UI_OFF"
        done
    fi
    printf '  %s%s%s\n' "$UI_DIM" "$(ui_repeat $((w - 3)) "$UI_H")" "$UI_OFF"
}