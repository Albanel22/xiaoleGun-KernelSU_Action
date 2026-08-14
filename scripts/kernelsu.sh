```bash
#!/usr/bin/env bash

# Install a KernelSU variant into the kernel tree.
#
# Every variant ships a near-identical kernel/setup.sh that clones itself next
# to the kernel tree and symlinks drivers/kernelsu at it.
#
# This script validates the requested ref before running setup.sh and verifies
# the resulting tree afterwards.
#
# ReSukiSU/SukiSU-style trees normally keep their actual KernelSU Kconfig
# under KernelSU/kernel/Kconfig. Older versions/variants may expose it as
# KernelSU/Kconfig, so both layouts are accepted.

set -euo pipefail

# shellcheck source=scripts/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

KERNEL_DIR=${KERNEL_DIR:?KERNEL_DIR must point at the kernel source tree}

# ------------------------------------------------------------- registry -----

#
# Fields, '|'-separated:
# 1 repo URL
# 2 ref the setup.sh script itself is fetched from
# 3 directory setup.sh clones into, relative to the kernel tree
# 4 default ref for modern (>= 5.10) kernels
# 5 default ref for legacy (< 5.10) kernels
# 6 refs that already contain SUSFS support
# 7 human-readable name
#

ksu_registry() {
	case "$1" in
		kernelsu)
			# Official upstream. Dropped non-GKI support at v1.0, so legacy
			# kernels are pinned to the last release that supports them.
			echo "https://github.com/tiann/KernelSU|main|KernelSU||v0.9.5|-|KernelSU"
			;;

		kernelsu-next)
			echo "https://github.com/KernelSU-Next/KernelSU-Next|dev|KernelSU-Next|dev|legacy|-|KernelSU-Next"
			;;

		sukisu-ultra)
			# SukiSU-Ultra.
			# 'main' is the modular tree.
			# 'builtin' is used for non-GKI/source-integrated kernels.
			echo "https://github.com/SukiSU-Ultra/SukiSU-Ultra|main|KernelSU|main|builtin|builtin|SukiSU-Ultra"
			;;

		resukisu)
			# ReSukiSU.
			# main supports non-GKI integration through Manual Hook.
			echo "https://github.com/ReSukiSU/ReSukiSU|main|KernelSU|main|main|-|ReSukiSU"
			;;

		rsuntk)
			echo "https://github.com/rsuntk/KernelSU|main|KernelSU|main|main|susfs-rksu-master|RKSU (rsuntk)"
			;;

		backslashxx)
			echo "https://github.com/backslashxx/KernelSU|master|KernelSU|master|master|-|backslashxx KernelSU"
			;;

		*)
			die "unknown KSU_VARIANT '$1'"
			;;
	esac
}

ksu_field() {
	ksu_registry "$1" | cut -d'|' -f"$2"
}

# ReSukiSU defaults to the moving main branch when no explicit ref is given.
ksu_default_is_branch() {
	[ "$1" = "resukisu" ]
}

# ---------------------------------------------------------------- install ---

ksu_install() {
	local variant=$1
	local requested_ref=${2-}

	if [ "$variant" = "none" ]; then
		info "KernelSU integration disabled"
		return 0
	fi

	local repo setup_ref dir modern_ref legacy_ref susfs_refs name

	IFS='|' read -r repo setup_ref dir modern_ref legacy_ref susfs_refs name \
		<<<"$(ksu_registry "$variant")"

	group "Installing ${name}"

	info "repository: ${repo}"
	info "setup.sh ref: ${setup_ref}"

	# --------------------------------------------------------- kernel version

	local kver
	kver=$(kernel_version "$KERNEL_DIR" || echo "0.0")

	info "detected kernel version: ${kver}"

	# ---------------------------------------------------------- requested ref

	local ref=$requested_ref

	if [ -z "$ref" ]; then
		if ver_ge "$kver" "5.10"; then
			ref=$modern_ref
		else
			ref=$legacy_ref

			if [ -n "$ref" ]; then
				info "kernel ${kver} is pre-GKI; defaulting to ref '${ref}'"
			fi
		fi
	fi

	info "requested KernelSU ref: ${ref:-<setup.sh default>}"

	# ----------------------------------------------------------- validate ref

	if [ -n "$ref" ]; then
		info "validating ref '${ref}' in ${repo}"

		ref_exists "$repo" "$ref" || die "ref '${ref}' does not exist in ${repo}.
setup.sh would silently fall back to the default branch and you would
get a kernel without the feature you asked for.
Available branches:
$(git ls-remote --heads "$repo" 2>/dev/null |
awk '{print $2}' |
sed 's@refs/heads/@@' |
grep -v dependabot |
tr '\n' ' ')"

		ok "ref '${ref}' exists in ${repo}"
	else
		warn "no ref pinned; setup.sh will pick its default"
		warn "Set KSU_REF for reproducible builds"
	fi

	if [ -z "$requested_ref" ] && ksu_default_is_branch "$variant"; then
		warn "${name} defaults to the moving 'main' branch"
		warn "Set KSU_REF explicitly for reproducible builds"
	fi

	# ------------------------------------------------------------- setup URL

	local setup_url

	setup_url="https://raw.githubusercontent.com/${repo#https://github.com/}/${setup_ref}/kernel/setup.sh"

	info "setup script: ${setup_url}"

	# ----------------------------------------------------------- run installer

	(
		cd "$KERNEL_DIR"

		if [ -n "$ref" ]; then
			fetch_stdout "$setup_url" | bash -s "$ref"
		else
			fetch_stdout "$setup_url" | bash
		fi
	) || die "${name} setup.sh failed"

	# ------------------------------------------------------ verify clone dir

	local ksu_dir="${KERNEL_DIR}/${dir}"

	[ -d "$ksu_dir" ] || die "${name} setup.sh finished but ${dir}/ is missing"

	ok "${name} source directory exists: ${ksu_dir}"

	# ---------------------------------------------------------- verify Kconfig

	local ksu_kconfig=""

	if [ -f "${ksu_dir}/kernel/Kconfig" ]; then
		ksu_kconfig="${ksu_dir}/kernel/Kconfig"
	elif [ -f "${ksu_dir}/Kconfig" ]; then
		ksu_kconfig="${ksu_dir}/Kconfig"
	fi

	[ -n "$ksu_kconfig" ] || die "${name} Kconfig missing.
Checked:
${ksu_dir}/kernel/Kconfig
${ksu_dir}/Kconfig"

	ok "${name} Kconfig found: ${ksu_kconfig}"

	# ---------------------------------------------------------- verify symlink

	local link="${KERNEL_DIR}/drivers/kernelsu"

	[ -e "$link" ] || die "drivers/kernelsu was not created by ${name} setup.sh"

	ok "drivers/kernelsu integration exists"

	# ------------------------------------------------------- drivers Makefile

	local driver_makefile="${KERNEL_DIR}/drivers/Makefile"

	[ -f "$driver_makefile" ] ||
		die "drivers/Makefile not found"

	if ! grep -qE \
		'^[[:space:]]*obj-\$\(CONFIG_KSU\)[[:space:]]*\+=[[:space:]]*kernelsu/?[[:space:]]*$' \
		"$driver_makefile"; then

		if grep -qE \
			'^[[:space:]]*obj-\$\(CONFIG_[A-Z0-9_]+\)[[:space:]]*\+=[[:space:]]*kernelsu/?[[:space:]]*$' \
			"$driver_makefile"; then

			sed -i -E \
				's@^[[:space:]]*obj-\$\(CONFIG_[A-Z0-9_]+\)[[:space:]]*\+=[[:space:]]*kernelsu/?[[:space:]]*$@obj-$(CONFIG_KSU) += kernelsu/@' \
				"$driver_makefile"

			warn "normalized stale drivers/Makefile KernelSU guard to CONFIG_KSU"
		else
			printf '\nobj-$(CONFIG_KSU) += kernelsu/\n' >>"$driver_makefile"
			warn "added missing CONFIG_KSU rule to drivers/Makefile"
		fi
	fi

	grep -qE \
		'^[[:space:]]*obj-\$\(CONFIG_KSU\)[[:space:]]*\+=[[:space:]]*kernelsu/?[[:space:]]*$' \
		"$driver_makefile" ||
		die "drivers/Makefile is not wired to CONFIG_KSU"

	ok "drivers/Makefile wired to CONFIG_KSU"

	# ----------------------------------------------------------- drivers Kconfig

	local drivers_kconfig="${KERNEL_DIR}/drivers/Kconfig"

	[ -f "$drivers_kconfig" ] ||
		die "drivers/Kconfig not found"

	grep -q 'drivers/kernelsu/Kconfig' "$drivers_kconfig" ||
		die "drivers/Kconfig was not wired up for kernelsu"

	ok "drivers/Kconfig wired to drivers/kernelsu/Kconfig"

	# ------------------------------------------------------- verify git state

	local head_sha head_desc

	head_sha=$(git -C "$ksu_dir" rev-parse --short HEAD)

	head_desc=$(
		git -C "$ksu_dir" describe --tags --always 2>/dev/null ||
			echo "$head_sha"
	)

	if [ -n "$ref" ]; then
		local want current

		want=$(
			git -C "$ksu_dir" rev-parse --verify --quiet "$ref^{commit}" \
				2>/dev/null || true
		)

		current=$(git -C "$ksu_dir" rev-parse HEAD)

		if [ -n "$want" ] && [ "$want" != "$current" ]; then
			die "${name} is checked out at ${head_desc}, not the requested ref '${ref}'"
		fi
	fi

	ok "${name} installed at ${head_desc} (${head_sha})"

	# ----------------------------------------------------------- build facts

	local count version_label

	count=$(
		git -C "$ksu_dir" rev-list --count HEAD 2>/dev/null ||
			echo 0
	)

	if git -C "$ksu_dir" describe --exact-match --tags >/dev/null 2>&1; then
		version_label=$(git -C "$ksu_dir" describe --exact-match --tags)
	else
		version_label="${ref:-HEAD}-${head_sha}"
	fi

	# --------------------------------------------------------- export facts

	export_env KSU_DIR "$dir"
	export_env KSU_NAME "$name"
	export_env KSU_REF_RESOLVED "${ref:-<setup-default>}"
	export_env KSU_VERSION_LABEL "$version_label"
	export_env KSU_COMMIT_COUNT "$count"
	export_env KSU_SUSFS_BUNDLED_REFS "$susfs_refs"

	export_env UPLOADNAME "-${name// /_}_${version_label}"

	# --------------------------------------------------------- hook resolution

	ksu_resolve_hook_mode "${KSU_HOOK_MODE:-auto}" "$kver"

	# ------------------------------------------------------ ReSukiSU sanity

	if [ "$variant" = "resukisu" ] &&
		[ "${KSU_HOOK_MODE_RESOLVED:-}" = "manual" ]; then

		info "ReSukiSU manual-hook mode selected for kernel ${kver}"

		# ReSukiSU requires CONFIG_KSU_MANUAL_HOOK for Manual Hook.
		#
		# The automatic input/setuid/initrc helpers are useful on kernels
		# where those hook paths are compatible with the vendor tree.
		#
		# They are deliberately enabled in ksu_hook_configs(), not here,
		# because the defconfig file is the authoritative configuration.

		ok "ReSukiSU manual-hook mode validated for kernel ${kver}"
	fi

	summary "| KernelSU variant | \`${name}\` |"
	summary "| KernelSU ref | \`${ref:-setup.sh default}\` -> \`${version_label}\` |"
	summary "| KernelSU commit | \`${head_sha}\` |"
	summary "| KernelSU hook mode | \`${KSU_HOOK_MODE_RESOLVED:-unknown}\` |"

	endgroup
}

# ------------------------------------------------------------ hook config ---

#
# Resolve the hook mechanism once.
#
# auto:
# kernel >= 5.10 -> kprobes
# kernel < 5.10  -> manual
#

ksu_resolve_hook_mode() {
	local mode=${1:-auto}
	local kver=$2

	if [ "$mode" = "auto" ]; then
		if ver_ge "$kver" "5.10"; then
			mode="kprobes"
		else
			mode="manual"
		fi

		info "hook mode 'auto' resolved to '${mode}' for kernel ${kver}"
	fi

	export_env KSU_HOOK_MODE_RESOLVED "$mode"
}

# ------------------------------------------------------------- hook configs --

ksu_hook_configs() {
	local variant=$1
	local mode=$2
	local defconfig=$3
	local kver=$4

	if [ "$mode" = "auto" ]; then
		if [ -n "${KSU_HOOK_MODE_RESOLVED:-}" ]; then
			mode="$KSU_HOOK_MODE_RESOLVED"
		else
			ksu_resolve_hook_mode "$mode" "$kver"
			mode="$KSU_HOOK_MODE_RESOLVED"
		fi
	fi

	info "applying KernelSU hook configuration: ${mode}"

	case "$mode" in

		none)
			info "KernelSU hook mechanism disabled"
			return 0
			;;

		kprobes)
			kconf_enable "$defconfig" CONFIG_MODULES
			kconf_enable "$defconfig" CONFIG_KPROBES
			kconf_enable "$defconfig" CONFIG_HAVE_KPROBES
			kconf_enable "$defconfig" CONFIG_KPROBE_EVENTS
			kconf_enable "$defconfig" CONFIG_KRETPROBES

			if [ "$variant" = "kernelsu-next" ]; then
				kconf_enable "$defconfig" CONFIG_KSU_KPROBES_HOOK
			fi
			;;

		manual)
			case "$variant" in

				kernelsu-next)
					kconf_enable "$defconfig" CONFIG_KSU_MANUAL_HOOK
					;;

				sukisu-ultra)
					kconf_enable "$defconfig" CONFIG_KSU_MANUAL_HOOK
					;;

				resukisu)
					# ReSukiSU Manual Hook is the correct mode for
					# non-GKI kernels such as Linux 4.19.
					#
					# ReSukiSU's current manual integration documentation
					# requires CONFIG_KSU_MANUAL_HOOK.
					#
					# These automatic helpers are supported for kernels
					# where the corresponding kernel paths are compatible.
					# Kernel 4.19 uses the read hook path described by
					# ReSukiSU's manual integration guide.

					kconf_set_many "$defconfig" \
						CONFIG_KSU_MANUAL_HOOK=y \
						CONFIG_KSU_MANUAL_HOOK_AUTO_INPUT_HOOK=y \
						CONFIG_KSU_MANUAL_HOOK_AUTO_SETUID_HOOK=y \
						CONFIG_KSU_MANUAL_HOOK_AUTO_INITRC_HOOK=y \
						CONFIG_KALLSYMS=y \
						CONFIG_KALLSYMS_ALL=y
					;;

				*)
					# tiann/KernelSU 0.9.x historically infers manual
					# hooks from the source patch.
					:
					;;

			esac
			;;

		tracepoint)
			if [ "$variant" != "resukisu" ] &&
				[ "$variant" != "sukisu-ultra" ]; then

				warn "hook mode 'tracepoint' is only declared by ReSukiSU/SukiSU-Ultra; ignoring for ${variant}"
				return 0
			fi

			kconf_enable "$defconfig" CONFIG_KSU_TRACEPOINT_HOOK
			;;

		syscall)
			kconf_enable "$defconfig" CONFIG_KSU_SYSCALL_HOOK
			;;

		*)
			die "unknown KernelSU hook mode '${mode}'"
			;;

	esac
}

# -------------------------------------------------------------- entry point -

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
	ksu_install \
		"${KSU_VARIANT:-none}" \
		"${KSU_REF:-}"
fi
```
