#!/bin/bash
#
# Power and Apple-silicon efficiency check for SoundFlow.
#
# Why a shell harness and not XCTest: energy behaviour only exists in the real
# running app — a unit test process has no menu bar, no SwiftUI redraw loop and
# no CoreAudio IOProc, which is where this app's power actually goes.
#
# Everything here works WITHOUT sudo. `top` reports the same "Energy Impact"
# number Activity Monitor shows, plus idle wakeups, per process. The optional
# `deep` mode prints a powermetrics command for you to run yourself.
#
# Usage:
#   ./scripts/power-test.sh audit               static: arch, Rosetta, build
#   ./scripts/power-test.sh sample [label] [s]  measure the running app
#   ./scripts/power-test.sh compare [s]         guided idle vs window-open A/B
#   ./scripts/power-test.sh deep                powermetrics instructions
#   ./scripts/power-test.sh                     audit + a 15s sample

set -uo pipefail

BUNDLE_ID="com.soundflow.app"
DEFAULT_SECONDS=15

# Thresholds for an idle menu bar utility on Apple silicon. Idle wakeups are the
# metric that matters most: each one pulls a core out of its low-power state,
# and a background app that never sleeps is what drains a battery overnight.
MAX_IDLE_CPU=1.0
MAX_IDLE_ENERGY=1.0
GOOD_WAKEUPS=5
MAX_WAKEUPS=15

bold()  { printf "\033[1m%s\033[0m\n" "$1"; }
pass()  { printf "  \033[32m✓\033[0m %s\n" "$1"; }
warn()  { printf "  \033[33m!\033[0m %s\n" "$1"; }
fail()  { printf "  \033[31m✗\033[0m %s\n" "$1"; }
info()  { printf "    %s\n" "$1"; }

find_pid() {
    pgrep -f "SoundFlow.app/Contents/MacOS/SoundFlowApp" | head -1
}

app_binary() {
    local pid
    pid="$(find_pid)"
    if [ -n "$pid" ]; then
        # Measure whatever is actually running, which may not be ./build.
        ps -p "$pid" -o comm= 2>/dev/null
    elif [ -x "build/SoundFlow.app/Contents/MacOS/SoundFlowApp" ]; then
        echo "build/SoundFlow.app/Contents/MacOS/SoundFlowApp"
    elif [ -x "/Applications/SoundFlow.app/Contents/MacOS/SoundFlowApp" ]; then
        echo "/Applications/SoundFlow.app/Contents/MacOS/SoundFlowApp"
    fi
}

# ── Static audit ────────────────────────────────────────────────────────

audit() {
    bold "Architecture"

    local host binary archs
    host="$(uname -m)"
    info "host: $host  ($(sysctl -n machdep.cpu.brand_string 2>/dev/null || echo unknown))"

    binary="$(app_binary)"
    if [ -z "$binary" ]; then
        fail "No SoundFlow binary found. Build it or launch the app first."
        return 1
    fi
    info "binary: $binary"

    archs="$(lipo -archs "$binary" 2>/dev/null)"
    info "slices: ${archs:-unknown}"

    if [ "$host" = "arm64" ]; then
        if [[ "$archs" == *arm64* ]]; then
            pass "Native arm64 — no Rosetta translation."
            if [[ "$archs" == *x86_64* ]]; then
                warn "Universal binary. Fine, but the x86_64 slice is dead weight on this Mac."
            fi
        else
            fail "No arm64 slice: this runs under Rosetta 2, which costs both CPU and power."
        fi
    else
        warn "Host is $host, not Apple silicon. Arm-specific checks skipped."
    fi

    # ASan makes every measurement meaningless, and it is easy to forget which
    # bundle is which after running scripts/build-asan.sh.
    if otool -L "$binary" 2>/dev/null | grep -q "libclang_rt.asan"; then
        fail "AddressSanitizer is linked. Numbers from this build are not representative."
    else
        pass "No sanitizer runtime linked."
    fi

    echo
    bold "Wakeup sources in the code"
    # These two intervals set the app's idle wakeup floor, so surface them here
    # rather than making the reader go and grep for them.
    local meter watchdog
    meter="$(grep -o 'withTimeInterval: [0-9.]*' Sources/SoundFlowApp/MixerEngine.swift 2>/dev/null | head -1 | awk '{print $2}')"
    watchdog="$(grep -o 'pollInterval: TimeInterval = [0-9.]*' Sources/SoundFlowCore/RouteWatchdog.swift 2>/dev/null | awk '{print $4}')"

    if [ -n "$meter" ]; then
        local hz
        hz="$(echo "scale=1; 1 / $meter" | bc 2>/dev/null)"
        info "meter timer:    ${meter}s  (~${hz} wakeups/s)"
        info "                MixerEngine.meterTimer — runs whether or not a route exists"
    fi
    if [ -n "$watchdog" ]; then
        local whz
        whz="$(echo "scale=1; 1 / $watchdog" | bc 2>/dev/null)"
        info "route watchdog: ${watchdog}s  (~${whz} wakeups/s, only while a route is live)"
    fi
    echo
}

# ── Runtime sampling ────────────────────────────────────────────────────

# Samples the live process and prints averages. `top`'s first sample reports
# values accumulated since launch, so it is always discarded.
sample() {
    local label="${1:-current}" seconds="${2:-$DEFAULT_SECONDS}"
    local pid
    pid="$(find_pid)"

    if [ -z "$pid" ]; then
        fail "SoundFlow is not running. Launch it, then re-run."
        return 1
    fi

    bold "Sampling \"$label\" — pid $pid, ${seconds}s"

    local raw
    raw="$(top -l "$((seconds + 1))" -s 1 -pid "$pid" \
              -stats pid,cpu,power,idlew,th,mem 2>/dev/null \
           | grep -E "^ *$pid ")"

    if [ -z "$raw" ]; then
        fail "No samples captured — did the process exit?"
        return 1
    fi

    # idlew is cumulative since launch, so the per-second rate is the delta
    # between consecutive samples.
    echo "$raw" | awk -v label="$label" \
                      -v max_cpu="$MAX_IDLE_CPU" \
                      -v max_energy="$MAX_IDLE_ENERGY" \
                      -v good_w="$GOOD_WAKEUPS" \
                      -v max_w="$MAX_WAKEUPS" '
    {
        n++
        cpu = $2 + 0
        energy = $3 + 0
        wake = $4; gsub(/[+-]/, "", wake); wake += 0
        threads = $5 + 0
        if (n == 1) { prev_wake = wake; next }   # discard since-launch sample
        cpu_sum += cpu; energy_sum += energy
        if (cpu > cpu_max) cpu_max = cpu
        wake_sum += (wake - prev_wake)
        prev_wake = wake
        thread_last = threads
        counted++
    }
    END {
        if (counted < 1) { print "    not enough samples"; exit 1 }
        cpu_avg = cpu_sum / counted
        energy_avg = energy_sum / counted
        wake_avg = wake_sum / counted

        printf "    CPU        avg %.2f%%   peak %.2f%%\n", cpu_avg, cpu_max
        printf "    Energy     avg %.2f     (Activity Monitor scale)\n", energy_avg
        printf "    Wakeups    avg %.1f/s\n", wake_avg
        printf "    Threads    %d\n", thread_last
        print ""

        status = 0
        if (cpu_avg <= max_cpu) printf "  \033[32m✓\033[0m CPU within %.1f%%\n", max_cpu
        else { printf "  \033[31m✗\033[0m CPU %.2f%% exceeds %.1f%%\n", cpu_avg, max_cpu; status = 1 }

        if (energy_avg <= max_energy) printf "  \033[32m✓\033[0m Energy impact within %.1f\n", max_energy
        else { printf "  \033[31m✗\033[0m Energy impact %.2f exceeds %.1f\n", energy_avg, max_energy; status = 1 }

        if (wake_avg <= good_w) printf "  \033[32m✓\033[0m Idle wakeups %.1f/s\n", wake_avg
        else if (wake_avg <= max_w) printf "  \033[33m!\033[0m Idle wakeups %.1f/s — above the %d/s target\n", wake_avg, good_w
        else { printf "  \033[31m✗\033[0m Idle wakeups %.1f/s exceeds %d/s\n", wake_avg, max_w; status = 1 }

        exit status
    }'
    local result=$?
    echo
    return $result
}

# ── Guided A/B ──────────────────────────────────────────────────────────

# The interesting comparison is not idle-vs-busy audio, it is window closed vs
# window open: the meter timer mutates observable state 12.5x/s, and every
# visible row re-renders on each tick whether or not the value changed.
compare() {
    local seconds="${1:-$DEFAULT_SECONDS}"

    bold "A/B: window closed vs window open"
    echo
    echo "  1. Close the SoundFlow window (Cmd+W). Leave the menu bar item alone."
    read -r -p "     Press return when ready... " _
    echo
    sample "window closed" "$seconds"

    echo "  2. Open the window (menu bar → Open SoundFlow) and leave it frontmost."
    read -r -p "     Press return when ready... " _
    echo
    sample "window open" "$seconds"

    echo "  3. Optional: set 2-3 apps below 100% so taps and the IOProc are live."
    read -r -p "     Press return when ready, or Ctrl-C to stop... " _
    echo
    sample "window open + routed" "$seconds"
}

# ── powermetrics ────────────────────────────────────────────────────────

deep() {
    local pid
    pid="$(find_pid)"
    bold "Deeper measurement (needs your password — run it yourself)"
    echo
    echo "  Per-process wakeups and energy over 30s:"
    echo
    echo "    sudo powermetrics --samplers tasks -i 1000 -n 30 \\"
    echo "      --show-process-energy --show-process-wakeups \\"
    echo "      | grep -E 'SoundFlow|ALL_TASKS'"
    echo
    echo "  Package power while the app is routing audio:"
    echo
    echo "    sudo powermetrics --samplers cpu_power -i 1000 -n 30"
    echo
    if [ -n "$pid" ]; then
        echo "  Thread-level detail for pid $pid (no sudo):"
        echo
        echo "    sample $pid 10 -file /tmp/soundflow-sample.txt"
        echo
    fi
    echo "  Interpreting it: an idle menu bar app should sit near 0% CPU with"
    echo "  single-digit wakeups. Sustained wakeups with no audio routed mean a"
    echo "  timer is running when it has nothing to do."
    echo
}

# ── Entry ───────────────────────────────────────────────────────────────

case "${1:-all}" in
    audit)   audit ;;
    sample)  sample "${2:-current}" "${3:-$DEFAULT_SECONDS}" ;;
    compare) compare "${2:-$DEFAULT_SECONDS}" ;;
    deep)    deep ;;
    all)     audit; sample "current state" "$DEFAULT_SECONDS" ;;
    *)
        echo "usage: $0 [audit|sample <label> <seconds>|compare <seconds>|deep]"
        exit 2
        ;;
esac
