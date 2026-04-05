#!/bin/bash
set -u
export LC_ALL=C

# =========================
# PATHS
# =========================
LOG_FILE="$HOME/cr/spectrum_scan_log.txt"
RUN_LOG="$HOME/cr/enb_controller_runtime.log"

ENB_B7_CONF="/root/openairinterface5g/ci-scripts/conf_files/enb.nsa.band7.25prb.usrpb200.conf"
ENB_B40_CONF="/root/openairinterface5g/ci-scripts/conf_files/enb.band40.25prb.usrpb200.conf"

STATE_DIR="/tmp/cr_oai_enb"
mkdir -p "$STATE_DIR"

BS_PID_FILE="${STATE_DIR}/bs.pid"
CYCLE_FILE="${STATE_DIR}/cycle.count"
LAST_SWEEP_FILE="${STATE_DIR}/last_sweep.id"
CURRENT_CONF_FILE="${STATE_DIR}/current_conf"

PENDING_RESTART_FILE="${STATE_DIR}/pending_restart.flag"
STOPPED_FOR_RECONFIG_FILE="${STATE_DIR}/stopped_for_reconfig.flag"
RESTART_TARGET_SWEEP_FILE="${STATE_DIR}/restart_target_sweep.id"

# =========================
# PARAMETERS
# =========================
MAX_CYCLES=10
SLEEP_BETWEEN=5

HALF_WINDOW_MHZ=12
NEW_BUSY_THRESHOLD="0.10"
STEP_MHZ=5

B40_MIN=2300
B40_MAX=2400

B7_MIN=2620
B7_MAX=2700

LTE_PROCESS_PATTERN='/root/openairinterface5g/.*/lte-softmodem'

# =========================
# POLICY
# =========================
if [ $# -ge 1 ]; then
    case "$1" in
        strict|STRICT|1) POLICY="STRICT" ;;
        soft|SOFT|2) POLICY="SOFT" ;;
        *) echo "Use: strict or soft"; exit 1 ;;
    esac
else
    echo "1 - strict"
    echo "2 - soft"
    read -r x
    [ "$x" = "2" ] && POLICY="SOFT" || POLICY="STRICT"
fi

# =========================
# GENERATE 5 MHz ALIGNED FREQUENCIES
# =========================
gen_freqs_aligned() {
    local min="$1"
    local max="$2"
    local step="$3"
    local half="$4"

    local start_raw=$((min + half))
    local stop_raw=$((max - half))

    local start=$(( ((start_raw + step - 1) / step) * step ))
    local stop=$(( (stop_raw / step) * step ))

    local arr=()
    local f="$start"

    while [ "$f" -le "$stop" ]; do
        arr+=("$f")
        f=$((f + step))
    done

    echo "${arr[@]}"
}

ALLOWED_B40=($(gen_freqs_aligned "$B40_MIN" "$B40_MAX" "$STEP_MHZ" "$HALF_WINDOW_MHZ"))
ALLOWED_B7=($(gen_freqs_aligned "$B7_MIN" "$B7_MAX" "$STEP_MHZ" "$HALF_WINDOW_MHZ"))

# =========================
# LOGGING
# =========================
log() {
    local msg="[$(date '+%F %T')] $*"
    echo "$msg" | tee -a "$RUN_LOG" >&2
}

# =========================
# STATE
# =========================
init() {
    [ -f "$CYCLE_FILE" ] || echo 0 > "$CYCLE_FILE"
    [ -f "$LAST_SWEEP_FILE" ] || echo -1 > "$LAST_SWEEP_FILE"
    [ -f "$CURRENT_CONF_FILE" ] || echo "$ENB_B7_CONF" > "$CURRENT_CONF_FILE"
    [ -f "$RUN_LOG" ] || touch "$RUN_LOG"

    echo 0 > "$PENDING_RESTART_FILE"
    echo 0 > "$STOPPED_FOR_RECONFIG_FILE"
    echo -1 > "$RESTART_TARGET_SWEEP_FILE"
}

cycle() { cat "$CYCLE_FILE"; }
set_cycle() { echo "$1" > "$CYCLE_FILE"; }

pending_restart() { cat "$PENDING_RESTART_FILE"; }
set_pending_restart() { echo "$1" > "$PENDING_RESTART_FILE"; }

stopped_for_reconfig() { cat "$STOPPED_FOR_RECONFIG_FILE"; }
set_stopped_for_reconfig() { echo "$1" > "$STOPPED_FOR_RECONFIG_FILE"; }

restart_target_sweep() { cat "$RESTART_TARGET_SWEEP_FILE"; }
set_restart_target_sweep() { echo "$1" > "$RESTART_TARGET_SWEEP_FILE"; }

clear_restart_state() {
    set_pending_restart 0
    set_stopped_for_reconfig 0
    set_restart_target_sweep -1
}

# =========================
# BS CONTROL
# =========================
is_running() {
    pgrep -f "$LTE_PROCESS_PATTERN" >/dev/null 2>&1
}

record_running_pid() {
    pgrep -f "$LTE_PROCESS_PATTERN" | head -n 1 > "$BS_PID_FILE" 2>/dev/null || true
}

start_bs() {
    if is_running; then
        record_running_pid
        log "STAGE=START eNB is already running"
        return 0
    fi

    local conf
    conf=$(cat "$CURRENT_CONF_FILE")

    local cmd
    if [[ "$conf" == *band7* ]]; then
        cmd="sudo /usr/sbin/capsh --drop=cap_net_admin -- -c 'exec /root/openairinterface5g/cmake_targets/ran_build/build/lte-softmodem -O $ENB_B7_CONF'"
    else
        cmd="sudo /usr/sbin/capsh --drop=cap_net_admin -- -c 'exec /root/openairinterface5g/cmake_targets/ran_build/build/lte-softmodem -O $ENB_B40_CONF'"
    fi

    bash -c "$cmd" &
    sleep 2

    if is_running; then
        record_running_pid
        log "STAGE=START eNB started"
        return 0
    else
        log "STAGE=START eNB start failed"
        return 1
    fi
}

stop_bs() {
    if ! is_running; then
        rm -f "$BS_PID_FILE"
        log "STAGE=STOP eNB is already stopped"
        return 0
    fi

    log "STAGE=STOP sending SIGINT to lte-softmodem"
    pkill -INT -f "$LTE_PROCESS_PATTERN"
    sleep 3

    if is_running; then
        log "STAGE=STOP SIGINT did not stop eNB, sending SIGTERM"
        pkill -TERM -f "$LTE_PROCESS_PATTERN"
        sleep 2
    fi

    if is_running; then
        log "STAGE=STOP eNB is still running after SIGTERM"
        pgrep -af "$LTE_PROCESS_PATTERN" >&2 || true
        return 1
    else
        rm -f "$BS_PID_FILE"
        log "STAGE=STOP eNB stopped"
        return 0
    fi
}

# =========================
# READ CONFIG
# =========================
read_current_band() {
    local conf
    conf=$(cat "$CURRENT_CONF_FILE")

    grep -E '^[[:space:]]*eutra_band[[:space:]]*=' "$conf" \
    | sed -E 's/.*=[[:space:]]*([0-9]+).*/\1/'
}

read_current_freq() {
    local conf
    conf=$(cat "$CURRENT_CONF_FILE")

    grep -E '^[[:space:]]*downlink_frequency[[:space:]]*=' "$conf" \
    | sed -E 's/.*=[[:space:]]*([0-9]+)L?;.*/\1/' \
    | awk '{printf "%.0f\n", $1/1000000}'
}

window_start_freq() {
    local center="$1"
    echo $((center - HALF_WINDOW_MHZ))
}

# =========================
# PARSE LOG
# =========================
parse_log() {
    tail -n 5000 "$LOG_FILE" 2>/dev/null \
    | sed -nE 's/.*\| *([0-9]+) MHz *\| *(FREE|BUSY).*?\(([0-9]+) active bins\).*/\1 \2 \3/p'
}

last_sample() {
    parse_log | tail -n 1
}

# =========================
# SWEEP HELPERS
# =========================
get_complete_sweep_id() {
    parse_log | awk '
    BEGIN { prev=""; id=0 }
    {
        if(prev != "" && prev - $1 > 20) id++
        prev = $1
    }
    END {
        if(id < 1) print ""
        else print id-1
    }'
}

get_complete_sweep_by_id() {
    local wanted="$1"
    parse_log | awk -v want="$wanted" '
    BEGIN { prev=""; id=0 }
    {
        if(prev != "" && prev - $1 > 20) id++
        if(id == want) print
        prev = $1
    }'
}

get_live_sweep_id() {
    parse_log | awk '
    BEGIN { prev=""; id=0 }
    {
        if(prev != "" && prev - $1 > 20) id++
        prev = $1
    }
    END { print id }'
}

# =========================
# CHECK SWEEP COVERAGE
# =========================
covers_range() {
    local data="$1"
    local rmin="$2"
    local rmax="$3"

    echo "$data" | awk -v lo="$rmin" -v hi="$rmax" '
    BEGIN { minf=999999; maxf=-999999; n=0 }
    {
        if($1 >= lo && $1 <= hi){
            n++
            if($1 < minf) minf=$1
            if($1 > maxf) maxf=$1
        }
    }
    END {
        if(n == 0) exit 1
        if(minf <= lo && maxf >= hi) exit 0
        exit 1
    }'
}

# =========================
# MODIFIED RATIO
# =========================
ratio() {
    local center="$1"
    local data="$2"

    echo "$data" | awk -v c="$center" -v w="$HALF_WINDOW_MHZ" '
    {
        if($1 >= c-w && $1 <= c+w){
            total++
            if($2 == "BUSY") busy++
            if($3 > 2) heavy++
        }
    }
    END {
        if(total == 0){
            print 1
            exit
        }

        busy_ratio = busy / total
        heavy_ratio = heavy / total

        if(heavy_ratio > 0.15) busy_ratio += 0.1
        else busy_ratio -= 0.1

        if(busy_ratio < 0) busy_ratio = 0
        if(busy_ratio > 1) busy_ratio = 1

        printf "%.4f\n", busy_ratio
    }'
}

# =========================
# BEST FREQUENCY SEARCH
# =========================
best_freq() {
    local arr=("${!1}")
    local data="$2"

    local strict=""
    local strict_r="999"

    local overall=""
    local overall_r="999"

    local f r

    for f in "${arr[@]}"; do
        r=$(ratio "$f" "$data")

        awk -v r="$r" -v b="$overall_r" 'BEGIN{exit !(r < b)}' && {
            overall="$f"
            overall_r="$r"
        }

        awk -v r="$r" -v t="$NEW_BUSY_THRESHOLD" 'BEGIN{exit !(r <= t)}' && {
            awk -v r="$r" -v b="$strict_r" 'BEGIN{exit !(r < b)}' && {
                strict="$f"
                strict_r="$r"
            }
        }
    done

    if [ "$POLICY" = "STRICT" ]; then
        [ -n "$strict" ] && echo "$strict $strict_r"
    else
        if [ -n "$strict" ]; then
            echo "$strict $strict_r"
        elif [ -n "$overall" ]; then
            echo "$overall $overall_r"
        fi
    fi
}

# =========================
# PATCH CONFIG
# =========================
patch_freq() {
    local f="$1"
    local hz=$((f * 1000000))
    local conf
    conf=$(cat "$CURRENT_CONF_FILE")

    log "STAGE=PATCH trying to patch ${f} MHz (${hz} Hz) in $conf"

    sudo cp "$conf" "${conf}.bak" 2>>"$RUN_LOG" || {
        log "STAGE=PATCH failed to create backup for $conf"
        return 1
    }

    sudo sed -i -E "s/downlink_frequency[[:space:]]*=[[:space:]]*[0-9]+L;/downlink_frequency = ${hz}L;/" "$conf" 2>>"$RUN_LOG" || {
        log "STAGE=PATCH sed failed while patching $conf"
        return 1
    }

    sudo grep -q "downlink_frequency[[:space:]]*=[[:space:]]*${hz}L;" "$conf" || {
        log "STAGE=PATCH verification failed in $conf"
        return 1
    }

    log "STAGE=PATCH frequency patched successfully: ${f} MHz"
}

# =========================
# CHOOSE BEST CONFIG FROM A SWEEP
# =========================
choose_best_from_sweep() {
    local data="$1"

    local best7 best40
    best7=$(best_freq ALLOWED_B7[@] "$data")
    best40=$(best_freq ALLOWED_B40[@] "$data")

    local f7 r7 f40 r40
    f7=$(echo "$best7" | awk '{print $1}')
    r7=$(echo "$best7" | awk '{print $2}')

    f40=$(echo "$best40" | awk '{print $1}')
    r40=$(echo "$best40" | awk '{print $2}')

    log "B7 best: ${f7:-none} (${r7:-n/a})"
    log "B40 best: ${f40:-none} (${r40:-n/a})"

    local best_band=""
    local best_f=""
    local best_r="999"

    if [ -n "${f7:-}" ]; then
        best_band="7"
        best_f="$f7"
        best_r="$r7"
    fi

    if [ -n "${f40:-}" ]; then
        if [ -z "$best_band" ] || awk -v a="$r40" -v b="$best_r" 'BEGIN{exit !(a < b)}'; then
            best_band="40"
            best_f="$f40"
            best_r="$r40"
        fi
    fi

    if [ -n "$best_f" ]; then
        echo "$best_band $best_f $best_r"
    fi
}

# =========================
# INITIAL CONFIGURATION
# =========================
initial_config_from_sweep() {
    local data="$1"

    local decision
    decision=$(choose_best_from_sweep "$data")

    local band freq score
    band=$(echo "$decision" | awk '{print $1}')
    freq=$(echo "$decision" | awk '{print $2}')
    score=$(echo "$decision" | awk '{print $3}')

    if [ -z "${freq:-}" ]; then
        log "No valid initial candidate under selected policy. eNB remains stopped."
        return 0
    fi

    log "Initial selection: Band $band @ $freq MHz ($score)"

    if [ "$band" = "7" ]; then
        echo "$ENB_B7_CONF" > "$CURRENT_CONF_FILE"
    else
        echo "$ENB_B40_CONF" > "$CURRENT_CONF_FILE"
    fi

    patch_freq "$freq" || return 1
    start_bs
    set_cycle 0
    clear_restart_state
    return 0
}

# =========================
# FORCED RECONFIGURATION
# =========================
reconfigure_from_sweep() {
    local data="$1"

    local decision
    decision=$(choose_best_from_sweep "$data")

    local band freq score
    band=$(echo "$decision" | awk '{print $1}')
    freq=$(echo "$decision" | awk '{print $2}')
    score=$(echo "$decision" | awk '{print $3}')

    if [ -z "${freq:-}" ]; then
        log "No valid candidate under selected policy in reconfiguration sweep. eNB remains stopped."
        set_cycle 0
        clear_restart_state
        return 0
    fi

    log "STAGE=RECONFIG result: Band $band @ $freq MHz ($score)"

    if [ "$band" = "7" ]; then
        echo "$ENB_B7_CONF" > "$CURRENT_CONF_FILE"
    else
        echo "$ENB_B40_CONF" > "$CURRENT_CONF_FILE"
    fi

    patch_freq "$freq" || return 1
    start_bs

    set_cycle 0
    clear_restart_state
    return 0
}

# =========================
# MAIN LOOP
# =========================
init
log "eNB controller started"
log "Policy mode: $POLICY"
log "Allowed B40 frequencies: ${ALLOWED_B40[*]}"
log "Allowed B7 frequencies: ${ALLOWED_B7[*]}"

while true; do
    if [ ! -f "$LOG_FILE" ]; then
        log "Spectrum log file not found: $LOG_FILE"
        sleep "$SLEEP_BETWEEN"
        continue
    fi

    sample=$(last_sample)
    if [ -n "$sample" ]; then
        last_freq=$(echo "$sample" | awk '{print $1}')
        last_state=$(echo "$sample" | awk '{print $2}')
        last_bins=$(echo "$sample" | awk '{print $3}')
        log "Heartbeat: last sample = ${last_freq} MHz, ${last_state}, bins=${last_bins}"
    else
        last_freq=""
        log "Heartbeat: no parsed spectrum samples yet"
    fi

    complete_sid=$(get_complete_sweep_id)
    last_complete_sid=$(cat "$LAST_SWEEP_FILE")
    live_sid=$(get_live_sweep_id)

    if [ "$(pending_restart)" = "1" ]; then
        target=$(restart_target_sweep)

        if [ "$target" -lt 0 ]; then
            log "STAGE=ARMED stale target sweep detected, clearing restart state"
            clear_restart_state
            sleep "$SLEEP_BETWEEN"
            continue
        fi

        if is_running && [ "$(stopped_for_reconfig)" = "0" ]; then
            current_freq=$(read_current_freq)
            window_start=$(window_start_freq "$current_freq")

            if [ -n "$last_freq" ] && [ "$live_sid" -eq "$target" ] && [ "$last_freq" -ge "$window_start" ]; then
                log "STAGE=ARMED reached current window start (${window_start} MHz) on target sweep ${target}"
                stop_bs || log "STAGE=ARMED stop_bs reported failure"
                if ! is_running; then
                    set_stopped_for_reconfig 1
                fi
            else
                log "STAGE=ARMED waiting on target sweep ${target}; live sweep=${live_sid}, window_start=${window_start} MHz"
            fi
        fi

        if [ -n "$complete_sid" ] && [ "$complete_sid" -ge "$target" ]; then
            target_data=$(get_complete_sweep_by_id "$target")

            if [ -z "$target_data" ]; then
                log "STAGE=ARMED target sweep $target complete but extraction failed; clearing restart state"
                clear_restart_state
                sleep "$SLEEP_BETWEEN"
                continue
            fi

            if ! covers_range "$target_data" "$B40_MIN" "$B40_MAX"; then
                log "STAGE=ARMED target sweep $target does not fully cover Band 40; clearing restart state"
                clear_restart_state
                sleep "$SLEEP_BETWEEN"
                continue
            fi

            if ! covers_range "$target_data" "$B7_MIN" "$B7_MAX"; then
                log "STAGE=ARMED target sweep $target does not fully cover Band 7; clearing restart state"
                clear_restart_state
                sleep "$SLEEP_BETWEEN"
                continue
            fi

            log "STAGE=RECONFIG target sweep $target fully collected. Reconfiguring eNB now."
            echo "$target" > "$LAST_SWEEP_FILE"
            reconfigure_from_sweep "$target_data" || log "STAGE=RECONFIG failed"
            sleep "$SLEEP_BETWEEN"
            continue
        else
            log "STAGE=ARMED waiting for completion of target sweep $target"
            sleep "$SLEEP_BETWEEN"
            continue
        fi
    fi

    if [ -z "$complete_sid" ]; then
        log "No complete sweep detected yet. Waiting."
        sleep "$SLEEP_BETWEEN"
        continue
    fi

    if [ "$complete_sid" = "$last_complete_sid" ]; then
        log "No new complete sweep yet. Waiting."
        sleep "$SLEEP_BETWEEN"
        continue
    fi

    data=$(get_complete_sweep_by_id "$complete_sid")
    if [ -z "$data" ]; then
        log "Sweep parser returned empty data for complete sweep $complete_sid. Waiting."
        sleep "$SLEEP_BETWEEN"
        continue
    fi

    if ! covers_range "$data" "$B40_MIN" "$B40_MAX"; then
        log "Sweep $complete_sid does not fully cover Band 40"
        sleep "$SLEEP_BETWEEN"
        continue
    fi

    if ! covers_range "$data" "$B7_MIN" "$B7_MAX"; then
        log "Sweep $complete_sid does not fully cover Band 7"
        sleep "$SLEEP_BETWEEN"
        continue
    fi

    echo "$complete_sid" > "$LAST_SWEEP_FILE"
    log "New completed sweep $complete_sid"

    if ! is_running; then
        log "eNB is not running. Performing initial selection from current sweep."
        initial_config_from_sweep "$data" || log "Initial configuration failed"
        sleep "$SLEEP_BETWEEN"
        continue
    fi

    c=$(cycle)
    next_cycle=$((c + 1))
    log "Sweep-based cycle number: $next_cycle / $MAX_CYCLES"

    if [ "$next_cycle" -lt "$MAX_CYCLES" ]; then
        log "STAGE=OBSERVE keeping current station frequency and configuration."
        set_cycle "$next_cycle"
        sleep "$SLEEP_BETWEEN"
        continue
    fi

    target_sweep=$((complete_sid + 1))
    log "STAGE=ARMED MAX_CYCLES reached. Arming restart for next sweep (target sweep = $target_sweep)."
    set_pending_restart 1
    set_stopped_for_reconfig 0
    set_restart_target_sweep "$target_sweep"
    set_cycle "$next_cycle"

    sleep "$SLEEP_BETWEEN"
done
