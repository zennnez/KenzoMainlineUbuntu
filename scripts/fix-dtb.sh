#!/usr/bin/env bash
# usage: fix-dtb.sh IN.dtb OUT.dtb
# Fixes known DTS problems directly in the COMPILED device tree, by looking nodes up (not by editing kernel source), so it
# works on whatever kernel tree you built and only needs a boot.img rebuild (no kernel rebuild). Idempotent. Only touches
# DTBs whose root compatible contains xiaomi,kenzo. build-bootimg.sh runs it automatically (KENZO_NO_DTB_FIX=1 to skip).
#
#  1. ADSP crash loop: the adsp node's "wdog" interrupt is SPI 289, the same SPI as its smd-edge, so every SMD message
#     from the ADSP is taken as a watchdog bite ("crash detected in adsp: type watchdog", crash #548...).
#     msm8953 (same LPASS block) uses SPI 293 for wdog. Fixed only when wdog == the smd-edge interrupt.
#  2. MSM8956 has 4x A53 + 2x A72, the DTS describes 4+4. Disables the CPU nodes whose `reg` is listed in
#     KENZO_DISABLE_CPUS (default "101 102": on kenzo cpu@100 and cpu@103 come up, 101/102 never do).
#     KENZO_DISABLE_CPUS=none  keeps all eight.
set -euo pipefail
IN="${1:?usage: $0 IN.dtb OUT.dtb}"; OUT="${2:?usage: $0 IN.dtb OUT.dtb}"
command -v fdtget >/dev/null && command -v fdtput >/dev/null || { echo "fdtget/fdtput missing: apt install device-tree-compiler" >&2; exit 1; }
[[ -s $IN ]] || { echo "no such dtb: $IN" >&2; exit 1; }
[[ "$IN" == "$OUT" ]] || cp -f "$IN" "$OUT"
D="$OUT"
changed=0
note() { echo "  dtb-fix: $*"; }

root_compat="$(fdtget -t s "$D" / compatible 2>/dev/null || true)"
if [[ "$root_compat" != *xiaomi,kenzo* ]]; then note "not a kenzo DTB ('$root_compat'), left untouched"; exit 0; fi

# print the path of the first node (depth-first) whose compatible list contains $1
find_node() {
	local want="$1" base="${2:-/}" n p c
	for n in $(fdtget -l "$D" "$base" 2>/dev/null); do
		p="${base%/}/$n"
		c="$(fdtget -t s "$D" "$p" compatible 2>/dev/null || true)"
		if [[ " $c " == *" $want "* ]]; then echo "$p"; return 0; fi
		find_node "$want" "$p" && return 0
	done
	return 1
}

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
[[ -f "$ROOT/scripts/env.sh" ]] && source "$ROOT/scripts/env.sh"

# ---- 1. ADSP configuration
if adsp="$(find_node qcom,msm8976-adsp-pil)"; then
	disable_adsp="${DISABLE_ADSP:-${SKIP_BROKEN:-true}}"
	if [[ "$disable_adsp" == "true" || "$disable_adsp" == "1" ]]; then
		st="$(fdtget -t s "$D" "$adsp" status 2>/dev/null || true)"
		if [[ "$st" != "disabled" ]]; then
			fdtput -t s "$D" "$adsp" status disabled
			note "adsp status -> disabled (SKIP_BROKEN=true / audio & sensors incomplete; saves power & memory)"
			changed=1
		else
			note "adsp already disabled (SKIP_BROKEN=true)"
		fi

		# Also disable SLIMbus audio controller node to eliminate 8s QMI timeout
		slim_node="/soc/slim-ngd@c140000"
		if fdtget -t s "$D" "$slim_node" compatible >/dev/null 2>&1; then
			sst="$(fdtget -t s "$D" "$slim_node" status 2>/dev/null || true)"
			if [[ "$sst" != "disabled" ]]; then
				fdtput -t s "$D" "$slim_node" status disabled
				note "slim-ngd status -> disabled (audio incomplete; eliminates 8s QMI wait timeout)"
				changed=1
			fi
		fi
	else
		read -ra w <<<"$(fdtget -t x "$D" "$adsp" interrupts-extended 2>/dev/null || true)"
		# first entry = <&intc type spi flags> (intc has 3 interrupt cells); hex words printed without 0x
		if [[ ${#w[@]} -ge 4 ]] && (( 16#${w[1]} == 0 )); then
			wdog=$((16#${w[2]}))
			smd=""
			for sub in $(fdtget -l "$D" "$adsp" 2>/dev/null); do
				if fdtget -t u "$D" "$adsp/$sub" qcom,smd-edge >/dev/null 2>&1; then
					smd="$(fdtget -t u "$D" "$adsp/$sub" interrupts 2>/dev/null | awk '{print $2}')"; break
				fi
			done
			if [[ -n $smd && $wdog -eq $smd ]]; then
				w[2]="$(printf '%x' 293)"
				fdtput -t x "$D" "$adsp" interrupts-extended "${w[@]}"
				note "adsp wdog IRQ SPI $wdog (== smd-edge IRQ) -> SPI 293"; changed=1
			else
				note "adsp wdog IRQ is SPI $wdog (smd-edge: ${smd:-?}): fine / not the known bug"
			fi
		else
			note "adsp interrupts-extended has an unexpected layout, left untouched"
		fi
	fi
else
	note "no qcom,msm8976-adsp-pil node in this DTB (nothing to do for the ADSP)"
fi

# ---- 2. nonexistent CPU cores
cpus="${KENZO_DISABLE_CPUS-101 102}"
if [[ $cpus != none && -n $cpus ]]; then
	for r in $cpus; do
		node="/cpus/cpu@$r"
		fdtget -t s "$D" "$node" compatible >/dev/null 2>&1 || { note "no $node in this DTB"; continue; }
		st="$(fdtget -t s "$D" "$node" status 2>/dev/null || true)"
		if [[ $st == disabled ]]; then note "$node already set to disabled"
		else fdtput -t s "$D" "$node" status disabled; note "$node (not present on MSM8956) -> status disabled"; changed=1; fi
	done
fi

# ---- 3. Realistic Thermal Trip Points (prevents false shutdown at 75C while preserving active cpufreq throttling)
# Upstream msm8976.dtsi mistakenly hardcodes critical trip at 75C (normal load temperature for Snapdragon mobile SoCs).
# All other Qualcomm SoCs (MSM8916, MSM8996, SDM845) set critical shutdown at 105C-110C.
# We set:
#   alert0 (hot/notify): 70C
#   alert1 (passive cpufreq throttling): 75C
#   crit (emergency hardware shutdown): 105C
for tz in $(fdtget -l "$D" /thermal-zones 2>/dev/null || true); do
	for trip in $(fdtget -l "$D" "/thermal-zones/$tz/trips" 2>/dev/null || true); do
		tpath="/thermal-zones/$tz/trips/$trip"
		ttype="$(fdtget -t s "$D" "$tpath" type 2>/dev/null || true)"
		tval="$(fdtget -t u "$D" "$tpath" temperature 2>/dev/null || true)"
		if [[ "$ttype" == "critical" && -n "$tval" && "$tval" -lt 100000 ]]; then
			fdtput -t u "$D" "$tpath" temperature 105000
			note "$tpath ($tval) -> 105000 (critical shutdown adjusted to safe hardware limit)"
			changed=1
		elif [[ "$ttype" == "passive" && -n "$tval" && "$tval" -lt 75000 ]]; then
			fdtput -t u "$D" "$tpath" temperature 75000
			note "$tpath ($tval) -> 75000 (passive throttling)"
			changed=1
		elif [[ "$ttype" == "hot" && -n "$tval" && "$tval" -lt 70000 ]]; then
			fdtput -t u "$D" "$tpath" temperature 70000
			note "$tpath ($tval) -> 70000 (hot notification)"
			changed=1
		fi
	done
done

# ---- 4. USB HS PHY v3p3 regulator (pm8950_l13) voltage range
# phy-qcom-usb-hs calls regulator_set_voltage_triplet(uphy->v3p3, 3050000, 3300000, 3300000).
# If min_uV == max_uV (3075000 == 3075000), the regulator framework blocks voltage changes (-EPERM),
# causing phy_power_on() to abort before sending the ULPI sequence or POR reset, resulting in USB
# device descriptor failure (Code 43) on the host PC.
# Setting min to 3050000 and max to 3300000 enables REGULATOR_CHANGE_VOLTAGE and lets the PHY power on.
l13_node="/remoteproc/smd-edge/rpm-requests/regulators/l13"
if fdtget -t u "$D" "$l13_node" regulator-min-microvolt >/dev/null 2>&1; then
	l13_min=$(fdtget -t u "$D" "$l13_node" regulator-min-microvolt)
	l13_max=$(fdtget -t u "$D" "$l13_node" regulator-max-microvolt)
	if [[ "$l13_min" -eq "$l13_max" ]]; then
		fdtput -t u "$D" "$l13_node" regulator-min-microvolt 3050000
		fdtput -t u "$D" "$l13_node" regulator-max-microvolt 3300000
		note "pm8950_l13 regulator-min/max-microvolt (fixed $l13_min) -> 3050000..3300000 (enables USB HS PHY power-on)"
		changed=1
	else
		note "pm8950_l13 voltage range already variable ($l13_min..$l13_max)"
	fi
fi

[[ $changed -eq 1 ]] && note "wrote $OUT" || note "no changes needed"
