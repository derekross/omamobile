# SPDX-License-Identifier: MIT
# Sourced by stock-inventory-init after the NV guard succeeds.
# shellcheck disable=SC2154

stock_dc_be_csr_votes() {
    phase=$1
    expected_be=$2
    votes=
    for domain in sswrp_dpu_pd dpu_be_pd dpu_fe0_pd dpu_fe1_pd dpu_dsi0_pd dpu_dsi1_pd dpu_dp0_pd; do
        vote=$("$bb" timeout 3 "$bb" cat "$debugfs/power_controller/$domain/state") || return 1
        case $domain in
            sswrp_dpu_pd)
                case $phase:$vote in
                    sample:1|before:[01]|after:[01]) ;;
                    *) return 1 ;;
                esac ;;
            dpu_be_pd) [ "$vote" = "$expected_be" ] || return 1 ;;
            *) [ "$vote" = 0 ] || return 1 ;;
        esac
        votes="$votes $domain=$vote"
    done
    stock_inventory_log "DC BE CSR votes $phase$votes"
}

stock_dc_be_csr_cleanup() {
    failed=0
    if [ "$loaded" = yes ]; then
        "$bb" timeout 8 "$bb" rmmod grizzly_stock_be_csr || failed=1
    fi
    "$bb" umount "$debugfs" || failed=1
    return "$failed"
}

stock_dc_be_csr_cells() {
    bytes=$("$bb" od -An -tx1 -v "$1") || return 1
    [ "$(printf '%s' "$bytes" | "$bb" tr -d '[:space:]')" = "$2" ]
}

stock_dc_be_csr_trace() (
    module=/grizzly-inventory/grizzly_stock_be_csr.ko
    digest=/grizzly-inventory/grizzly_stock_be_csr.sha256
    params=/sys/module/grizzly_stock_be_csr/parameters
    debugfs=/grizzly-inventory/be-csr-debugfs
    tree=/sys/firmware/devicetree/base/sswrp_dpu@f400000

    [ "$("$bb" uname -r)" = 6.12.81-android16-6-gf5369e7496cb-ab16467452-4k ] || return 1
    for node in dc9x00@200000 display-subsystem dsi2host@3d8000 dsi2host@3f8000 \
        dw_mipi_cdphy@3c0000 dw_mipi_cdphy@3e0000 dp-encoder; do
        status=$("$bb" tr -d '\000' < "$tree/$node/status") || return 1
        [ "$status" = disabled ] || return 1
    done
    node=$tree/be-csr@2d4004
    stock_dc_be_csr_cells "$node/reg" 002d400400000004 &&
        stock_dc_be_csr_cells "$node/power-domains" 000000a3 &&
        stock_dc_be_csr_cells "$node/interrupts-extended" 000000c600000004 ||
        return 1
    # shellcheck disable=SC2016
    "$bb" awk '
        $1 == "power_controller" { found++ }
        $1 ~ /^(vs_drm|mipi_dsi2h|mipi_cdphy|grizzly_stock_be_csr)$/ { bad = 1 }
        END { exit (bad || found != 1) }' /proc/modules || return 1
    [ -f "$module" ] && [ ! -L "$module" ] && [ -f "$digest" ] && [ ! -L "$digest" ] || return 1
    IFS= read -r expected < "$digest" || return 1
    checksum=$("$bb" sha256sum "$module") || return 1
    [ "${checksum%% *}" = "$expected" ] || return 1

    "$bb" mkdir -m 0700 "$debugfs" || return 1
    "$bb" mount -t debugfs -o ro,nosuid,nodev,noexec,mode=0700 debugfs "$debugfs" || return 1
    loaded=no
    trap 'stock_dc_be_csr_cleanup || stock_inventory_log "DC BE CSR cleanup failed"' 0

    stock_dc_be_csr_votes before 0 || {
        stock_inventory_log 'DC BE CSR skipped: initial vote guard failed'
        return 1
    }
    "$bb" insmod "$module" || return 1
    loaded=yes
    [ "$("$bb" cat "$params/armed")" = Y ] || return 1
    stock_dc_be_csr_votes sample 1 || {
        stock_inventory_log 'DC BE CSR skipped: powered vote guard failed'
        return 1
    }
    stock_inventory_log 'DC BE CSR requesting one guarded read with frame-start masked'
    sample=$("$bb" timeout 5 "$bb" cat "$params/sample_once") || return 1
    printf '%s\n' "$sample" | "$bb" grep -Eq '^raw=(0|0x[[:xdigit:]]+) mono_ns=[0-9]+$' ||
        return 1
    stock_inventory_log "DC BE CSR sample $sample"
    "$bb" timeout 8 "$bb" rmmod grizzly_stock_be_csr || return 1
    loaded=no

    # genpd may drop the vote from its queued power-off worker.
    attempt=0
    while [ "$attempt" -lt 5 ]; do
        if stock_dc_be_csr_votes after 0; then
            trap - 0
            stock_dc_be_csr_cleanup
            return $?
        fi
        "$bb" sleep 1 || return 1
        attempt=$((attempt + 1))
    done
    stock_inventory_log 'DC BE CSR release could not be verified'
    return 1
)
