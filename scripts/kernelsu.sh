#!/usr/bin/env bash
#
# Install and validate a KernelSU variant in the kernel tree.
#
# The installer is deliberately strict:
#   1. resolve the requested/default ref
#   2. validate the ref before calling setup.sh
#   3. run the upstream variant setup.sh
#   4. verify the resulting tree
#   5. verify that the requested ref was actually checked out
#   6. resolve the hook mode exactly once
#   7. export all facts required by later build/patch steps
#
# setup.sh scripts used by KernelSU forks historically swallow an invalid
# checkout ref and fall back to their default branch. Never rely on setup.sh
# to validate a ref.

set -euo pipefail

# shellcheck source=scripts/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

KERNEL_DIR=${KERNEL_DIR:?KERNEL_DIR must point at the kernel source tree}

# ------------------------------------------------------------- registry -----
#
# Fields:
#   1 repository
#   2 branch containing kernel/setup.sh
#   3 directory created inside the kernel tree
#   4 default ref for >= 5.10
#   5 default ref for < 5.10
#   6 refs known to bundle SUSFS
#   7 display name
#
# IMPORTANT:
# setup_ref is the branch containing setup.sh.
# install refs are independent of setup_ref.
#
# KernelSU-Next:
#   setup.sh lives on "next"
#   refs include dev/stable/legacy/specific tags.
#
# SukiSU-Ultra:
#   setup.sh lives on "main"
#   "main" is the GKI/main integration
#   "builtin" is the non-GKI/source-integrated tree.
#
ksu_registry() {
	local variant=$1

	case "$variant" in
		kernelsu)
			printf '%s\n' \
				"https://github.com/tiann/KernelSU|main|KernelSU||v0.9.5|-|KernelSU"
			;;

		kernelsu-next)
			printf '%s\n' \
				"https://github.com/KernelSU-Next/KernelSU-Next|next|KernelSU|dev|legacy|-|KernelSU-Next"
			;;

		sukisu-ultra)
			printf '%s\n' \
				"https://github.com/SukiSU-Ultra/SukiSU-Ultra|main|KernelSU|main|builtin|builtin|SukiSU-Ultra"
			;;

		resukisu)
			printf '%s\n' \
				"https://github.com/ReSukiSU/ReSukiSU|main|KernelSU|main|main|-|ReSukiSU"
			;;

		rsuntk)
			printf '%s\n' \
				"https://github.com/rsuntk/KernelSU|main|KernelSU|main|main|susfs-rksu-master|RKSU (rsuntk)"
			;;

		backslashxx)
			printf '%s\n' \
				"https://github.com/backslashxx/KernelSU|master|KernelSU|master|master|-|backslashxx KernelSU"
			;;

		*)
			die "unknown KSU_VARIANT '${variant}'"
			;;
	esac
}

ksu_field() {
	ksu_registry "$1" | cut -d'|' -f"$2"
}

# ------------------------------------------------------------- ref helpers ---

ksu_list_refs() {
	local repo=$1

	git ls-remote \
		--heads \
		--tags \
		"$repo" 2>/dev/null |
		awk '
			{
				ref=$2
				sub(/^refs\/heads\//, "", ref)
				sub(/^refs\/tags\//, "", ref)
				sub(/\^\{\}$/, "", ref)
				print ref
			}
		' |
		sort -u |
		grep -v '^$' |
		tr '\n' ' ' || true
}

ksu_ref_exists() {
	local repo=$1
	local ref=$2

	[ -n "$ref" ] || return 1

	# First use the common helper.
	if ref_exists "$repo" "$ref"; then
		return 0
	fi

	# Some annotated tags are exposed as refs/tags/name^{}.
	# Explicitly test both heads and tags as a fallback.
	if git ls-remote \
		--exit-code \
		--heads \
		--tags \
		"$repo" \
		"refs/heads/${ref}" \
		"refs/tags/${ref}" \
		"refs/tags/${ref}^{}" \
		>/dev/null 2>&1; then
		return 0
	fi

	# Full/short commit SHA.
	if printf '%s' "$ref" | grep -qE '^[0-9a-fA-F]{7,40}$'; then
		return 0
	fi

	return 1
}

# ------------------------------------------------------------- defaults ------

ksu_default_ref() {
	local variant=$1
	local kver=$2
	local modern_ref legacy_ref

	modern_ref=$(ksu_field "$variant" 4)
	legacy_ref=$(ksu_field "$variant" 5)

	if ver_ge "$kver" "5.10"; then
		printf '%s' "$modern_ref"
	else
		printf '%s' "$legacy_ref"
	fi
}

# ReSukiSU defaults to its moving main branch rather than a release tag.
ksu_default_is_branch() {
	[ "$1" = "resukisu" ]
}

# ------------------------------------------------------------- installation ---

ksu_install() {
	local variant=$1
	local requested_ref=${2-}

	[ "$variant" = "none" ] && {
		info "KernelSU integration disabled"
		return 0
	}

	local repo setup_ref dir modern_ref legacy_ref susfs_refs name
	IFS='|' read -r \
		repo \
		setup_ref \
		dir \
		modern_ref \
		legacy_ref \
		susfs_refs \
		name <<<"$(ksu_registry "$variant")"

	group "Installing ${name}"

	info "repository: ${repo}"
	info "setup.sh ref: ${setup_ref}"

	# --------------------------------------------------------- kernel version

	local kver
	kver=$(kernel_version "$KERNEL_DIR") \
		|| die "cannot determine kernel version from ${KERNEL_DIR}/Makefile"

	info "detected kernel version: ${kver}"

	# -------------------------------------------------------------- resolve ref

	local ref=$requested_ref

	if [ -z "$ref" ]; then
		ref=$(ksu_default_ref "$variant" "$kver")
	fi

	if [ -z "$ref" ]; then
		warn "no install ref selected for ${name}"
		warn "setup.sh will choose its own default"
	else
		info "requested KernelSU ref: ${ref}"
	fi

	# ------------------------------------------------------------- validate ref

	if [ -n "$ref" ]; then
		info "validating ref '${ref}' in ${repo}"

		if ! ksu_ref_exists "$repo" "$ref"; then
			die "ref '${ref}' does not exist in ${repo}.
   setup.sh would otherwise be able to silently fall back to its default.
   Available refs:
   $(ksu_list_refs "$repo")"
		fi

		ok "ref '${ref}' exists in ${repo}"
	else
		warn "no ref pinned; build is not fully reproducible"
	fi

	if [ -z "$requested_ref" ] && ksu_default_is_branch "$variant"; then
		warn "${name} defaults to the moving 'main' branch"
		warn "Set KSU_REF explicitly for reproducible builds"
	fi

	# ------------------------------------------------------------ setup URL

	local setup_url
	setup_url="https://raw.githubusercontent.com/${repo#https://github.com/}/${setup_ref}/kernel/setup.sh"

	info "setup script: ${setup_url}"

	# ---------------------------------------------------------- run setup.sh

	(
		cd "$KERNEL_DIR"

		if [ -n "$ref" ]; then
			fetch_stdout "$setup_url" | bash -s -- "$ref"
		else
			fetch_stdout "$setup_url" | bash
		fi
	) || die "${name} setup.sh failed"

	# ------------------------------------------------------- verify directory

	local ksu_dir="${KERNEL_DIR}/${dir}"

	[ -d "$ksu_dir" ] \
		|| die "${name} setup.sh finished but '${dir}/' is missing"

	local link="${KERNEL_DIR}/drivers/kernelsu"

	[ -e "$link" ] \
		|| die "drivers/kernelsu was not created"

	# ------------------------------------------------------- verify symlink

	if [ -L "$link" ]; then
		local link_target
		link_target=$(readlink "$link")

		debug "drivers/kernelsu -> ${link_target}"

		if [ ! -e "$link" ]; then
			die "drivers/kernelsu is a broken symlink"
		fi
	else
		warn "drivers/kernelsu is not a symlink; setup.sh created a directory/file"
	fi

	# ------------------------------------------------------ drivers Makefile

	local driver_makefile="${KERNEL_DIR}/drivers/Makefile"

	[ -f "$driver_makefile" ] \
		|| die "drivers/Makefile not found"

	if ! grep -qE \
		'^[[:space:]]*obj-\$\(CONFIG_KSU\)[[:space:]]*\+=[[:space:]]*kernelsu/?[[:space:]]*$' \
		"$driver_makefile"; then

		if grep -qE \
			'^[[:space:]]*obj-\$\(CONFIG_[A-Z0-9_]+\)[[:space:]]*\+=[[:space:]]*kernelsu/?[[:space:]]*$' \
			"$driver_makefile"; then

			sed -i -E \
				's@^[[:space:]]*obj-\$\(CONFIG_[A-Z0-9_]+\)[[:space:]]*\+=[[:space:]]*kernelsu/?[[:space:]]*$@obj-$(CONFIG_KSU) += kernelsu/@' \
				"$driver_makefile"

			warn "normalized stale KernelSU Makefile guard to CONFIG_KSU"
		else
			printf '\nobj-$(CONFIG_KSU) += kernelsu/\n' \
				>>"$driver_makefile"

			warn "added missing CONFIG_KSU rule to drivers/Makefile"
		fi
	fi

	grep -qE \
		'^[[:space:]]*obj-\$\(CONFIG_KSU\)[[:space:]]*\+=[[:space:]]*kernelsu/?[[:space:]]*$' \
		"$driver_makefile" \
		|| die "drivers/Makefile is not wired to CONFIG_KSU"

	# ----------------------------------------------------------- drivers/Kconfig

	local drivers_kconfig="${KERNEL_DIR}/drivers/Kconfig"

	[ -f "$drivers_kconfig" ] \
		|| die "drivers/Kconfig not found"

	if ! grep -q 'drivers/kernelsu/Kconfig' "$drivers_kconfig"; then
		die "drivers/Kconfig is not wired to drivers/kernelsu/Kconfig"
	fi

	# ----------------------------------------------------------- KSU Kconfig

	local ksu_kconfig="${ksu_dir}/Kconfig"

	[ -f "$ksu_kconfig" ] \
		|| die "${name} Kconfig missing: ${ksu_kconfig}"

	grep -qE '^[[:space:]]*(menu|config)[[:space:]].*KSU|config[[:space:]]+KSU' \
		"$ksu_kconfig" 2>/dev/null \
		|| warn "could not find an obvious KSU config declaration in ${ksu_kconfig}"

	# --------------------------------------------------------- actual checkout

	local head_sha
	local head_full_sha
	local head_desc

	head_full_sha=$(git -C "$ksu_dir" rev-parse HEAD 2>/dev/null) \
		|| die "cannot determine ${name} checkout commit"

	head_sha=${head_full_sha:0:12}

	head_desc=$(git -C "$ksu_dir" describe --tags --always 2>/dev/null \
		|| printf '%s' "$head_sha")

	info "${name} checkout: ${head_desc} (${head_sha})"

	# ----------------------------------------------------------- verify ref

	if [ -n "$ref" ]; then
		local wanted_sha=""
		local actual_sha="$head_full_sha"

		# Resolve the requested ref locally first.
		wanted_sha=$(
			git -C "$ksu_dir" rev-parse --verify --quiet "${ref}^{commit}" \
			2>/dev/null || true
		)

		# If it was not available locally, fetch the exact ref from origin.
		if [ -z "$wanted_sha" ]; then
			git -C "$ksu_dir" fetch -q --no-tags origin \
				"+refs/heads/${ref}:refs/remotes/origin/${ref}" \
				2>/dev/null || true

			wanted_sha=$(
				git -C "$ksu_dir" rev-parse --verify --quiet \
					"refs/remotes/origin/${ref}^{commit}" \
					2>/dev/null || true
			)
		fi

		if [ -n "$wanted_sha" ]; then
			if [ "$wanted_sha" != "$actual_sha" ]; then
				die "${name} checkout mismatch:
   requested ref : ${ref}
   requested SHA : ${wanted_sha}
   actual SHA    : ${actual_sha}
   actual commit : ${head_desc}"
			fi

			ok "${name} checkout matches requested ref '${ref}'"
		else
			warn "could not resolve '${ref}' locally after setup.sh"
			warn "actual checkout: ${head_desc} (${head_sha})"
			warn "continuing because this may be a detached commit/SHA"
		fi
	fi

	# -------------------------------------------------------- CONFIG_KSU check

	if grep -RqsE \
		'^[[:space:]]*config[[:space:]]+KSU([[:space:]]|$)' \
		"$ksu_dir"; then
		ok "KernelSU Kconfig declares CONFIG_KSU"
	else
		die "${name} installation does not declare CONFIG_KSU"
	fi

	# ----------------------------------------------------------- git metadata

	local count
	local version_label

	count=$(git -C "$ksu_dir" rev-list --count HEAD 2>/dev/null || printf '0')

	if git -C "$ksu_dir" describe --exact-match --tags >/dev/null 2>&1; then
		version_label=$(git -C "$ksu_dir" describe --exact-match --tags)
	else
		version_label="${ref:-HEAD}-${head_sha}"
	fi

	# ------------------------------------------------------------- exports

	export_env KSU_DIR "$dir"
	export_env KSU_NAME "$name"
	export_env KSU_REF_RESOLVED "${ref:-<setup.sh-default>}"
	export_env KSU_VERSION_LABEL "$version_label"
	export_env KSU_COMMIT "$head_full_sha"
	export_env KSU_COMMIT_SHORT "$head_sha"
	export_env KSU_COMMIT_COUNT "$count"
	export_env KSU_SUSFS_BUNDLED_REFS "$susfs_refs"

	export_env UPLOADNAME "-${name// /_}_${version_label}"

	# --------------------------------------------------------- hook resolution

	ksu_resolve_hook_mode \
		"${KSU_HOOK_MODE:-auto}" \
		"$kver"

	# -------------------------------------------------------------- summary

	summary "| KernelSU variant | \`${name}\` |"
	summary "| KernelSU setup ref | \`${setup_ref}\` |"
	summary "| KernelSU install ref | \`${ref:-setup.sh default}\` |"
	summary "| KernelSU commit | \`${head_sha}\` |"
	summary "| KernelSU version | \`${version_label}\` |"
	summary "| KernelSU hooks | \`${KSU_HOOK_MODE_RESOLVED:-unknown}\` |"

	ok "${name} installed successfully"
	endgroup
}

# ------------------------------------------------------------ hook config ----

#
# Resolve "auto" exactly once.
#
# GKI / modern kernels:
#   kprobes
#
# pre-GKI / legacy kernels:
#   manual
#
# This resolved value is exported and reused by patches.sh AND defconfig.sh.

ksu_resolve_hook_mode() {
	local mode=${1:-auto}
	local kver=$2

	case "$mode" in
		auto)
			if ver_ge "$kver" "5.10"; then
				mode="kprobes"
			else
				mode="manual"
			fi

			info "hook mode 'auto' resolved to '${mode}' for kernel ${kver}"
			;;

		kprobes|manual|tracepoint|syscall|none)
			;;

		*)
			die "invalid KSU_HOOK_MODE '${mode}'"
			;;
	esac

	export_env KSU_HOOK_MODE_RESOLVED "$mode"
}

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

	case "$mode" in
		none)
			info "KernelSU hook configuration disabled"
			return 0
			;;

		kprobes)
			kconf_enable "$defconfig" CONFIG_MODULES
			kconf_enable "$defconfig" CONFIG_KPROBES
			kconf_enable "$defconfig" CONFIG_KPROBE_EVENTS
			kconf_enable "$defconfig" CONFIG_KRETPROBES

			case "$variant" in
				kernelsu-next)
					# Current KernelSU-Next documentation uses
					# CONFIG_KSU_KPROBE_HOOKS.
					kconf_enable "$defconfig" CONFIG_KSU_KPROBE_HOOKS

					# Older trees used the singular form. Only add it
					# when the installed Kconfig actually declares it.
					if grep -Rqs \
						'config KSU_KPROBES_HOOK' \
						"${KERNEL_DIR:-.}/drivers/kernelsu" 2>/dev/null; then
						kconf_enable "$defconfig" CONFIG_KSU_KPROBES_HOOK
					fi
					;;

				sukisu-ultra|resukisu|rsuntk|backslashxx)
					# These variants may declare their own Kprobe option.
					# CONFIG_KPROBES itself is the mandatory kernel side.
					;;

				*)
					;;
			esac
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
					kconf_set_many "$defconfig" \
						CONFIG_KSU_MANUAL_HOOK=y \
						CONFIG_DEBUG_KERNEL=y \
						CONFIG_KALLSYMS=y \
						CONFIG_KALLSYMS_ALL=y
					;;

				rsuntk)
					# RKSU legacy integration generally relies on the
					# source hooks rather than the modern Kprobe path.
					;;

				backslashxx)
					# backslashxx hooks are applied by patches.sh.
					;;

				*)
					# Official KernelSU 0.9.x legacy integration gets its
					# hooks from the source patch.
					;;
			esac
			;;

		tracepoint)
			case "$variant" in
				resukisu|sukisu-ultra)
					kconf_enable "$defconfig" CONFIG_KSU_TRACEPOINT_HOOK
					;;

				*)
					warn "tracepoint hooks are not declared by ${variant}; leaving mode unchanged"
					;;
			esac
			;;

		syscall)
			if grep -Rqs \
				'config KSU_SYSCALL_HOOK' \
				"${KERNEL_DIR:-.}/drivers/kernelsu" 2>/dev/null; then
				kconf_enable "$defconfig" CONFIG_KSU_SYSCALL_HOOK
			else
				warn "${variant} does not declare CONFIG_KSU_SYSCALL_HOOK"
			fi
			;;

		*)
			die "internal error: unsupported resolved hook mode '${mode}'"
			;;
	esac
}

# ------------------------------------------------------------------- main -----

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
	ksu_install \
		"${KSU_VARIANT:-none}" \
		"${KSU_REF:-}"
fi
