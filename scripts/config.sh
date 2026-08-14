#!/usr/bin/env bash

# Resolve the build configuration, validate it, and export it to later steps.
#
# Resolution order (last wins):
#   1. built-in defaults
#   2. CONFIG_ENV / config.env
#   3. workflow_dispatch IN_<KEY> overrides
#
# The special workflow value "config" means:
#   "use the value from config.env"
#
# This keeps the Run workflow menu compatible with config.env while allowing
# individual options to override the file when explicitly selected.

set -euo pipefail

# shellcheck source=scripts/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CONFIG_FILE="${CONFIG_ENV:-config.env}"

# --------------------------------------------------------------- defaults ---

declare -A DEFAULTS=(
	[KERNEL_SOURCE]=""
	[KERNEL_SOURCE_BRANCH]=""
	[KERNEL_CONFIG]=""
	[KERNEL_IMAGE_NAME]="Image.gz-dtb"
	[ARCH]="arm64"
	[KERNEL_NAME]=""
	[ADD_LOCALVERSION_TO_FILENAME]="false"
	[EXTRA_CMDS]=""
	[CUSTOM_CMDS]=""

	# Toolchain
	[USE_CUSTOM_CLANG]="false"
	[CUSTOM_CLANG_SOURCE]=""
	[CUSTOM_CLANG_BRANCH]=""
	[CLANG_BRANCH]="main-kernel-2025"
	[CLANG_VERSION]="r547379"
	[USE_LLVM]="false"
	[ENABLE_GCC_ARM64]="false"
	[ENABLE_GCC_ARM32]="false"
	[USE_CUSTOM_GCC_64]="false"
	[CUSTOM_GCC_64_SOURCE]=""
	[CUSTOM_GCC_64_BRANCH]=""
	[CUSTOM_GCC_64_BIN]="aarch64-linux-android-"
	[USE_CUSTOM_GCC_32]="false"
	[CUSTOM_GCC_32_SOURCE]=""
	[CUSTOM_GCC_32_BRANCH]=""
	[CUSTOM_GCC_32_BIN]="arm-linux-androideabi-"

	# KernelSU
	[KSU_VARIANT]="none"
	[KSU_REF]=""
	[KSU_HOOK_MODE]="auto"
	[KSU_EXPECTED_SIZE]=""
	[KSU_EXPECTED_HASH]=""

	# Patches
	[ENABLE_SUSFS]="false"
	[SUSFS_REPO]="https://gitlab.com/simonpunk/susfs4ksu.git"
	[SUSFS_BRANCH]="auto"
	[ENABLE_PATH_UMOUNT]="false"
	[ENABLE_HIDE_STUFF]="false"
	[ENABLE_KPM]="false"

	# Kconfig tweaks
	[ADD_KPROBES_CONFIG]="false"
	[ADD_OVERLAYFS_CONFIG]="false"
	[DISABLE_LTO]="false"
	[DISABLE_CC_WERROR]="false"
	[EXTRA_DEFCONFIG]=""

	# Packaging
	[USE_CUSTOM_ANYKERNEL3]="false"
	[CUSTOM_ANYKERNEL3_SOURCE]=""
	[CUSTOM_ANYKERNEL3_BRANCH]=""
	[NEED_DTBO]="false"
	[BUILD_BOOT_IMG]="false"
	[SOURCE_BOOT_IMAGE]=""

	# Runner
	[ENABLE_CCACHE]="true"
	[REMOVE_UNUSED_PACKAGES]="true"
)

# --------------------------------------------------------------- aliases ----

# Legacy spellings kept for existing config.env files.
declare -A ALIASES=(
	[DISABLE-LTO]="DISABLE_LTO"
	[KERNELSU_TAG]="KSU_REF"
	[APPLY_KSU_PATCH]="_LEGACY_APPLY_KSU_PATCH"
	[ENABLE_KERNELSU]="_LEGACY_ENABLE_KERNELSU"
)

# ---------------------------------------------------------------- parsing ----

# cfg_read FILE KEY
#
# Reads the first active line matching:
#
#   KEY=value
#   KEY:value
#
# Leading whitespace is allowed.
# Lines beginning with # are ignored.
# '=' inside the value is preserved.
cfg_read() {
	local file="$1"
	local key="$2"

	[ -f "$file" ] || return 0

	sed -nE \
		"s/^[[:space:]]*${key}[[:space:]]*[=:][[:space:]]*(.*)$/\1/p" \
		"$file" |
		head -n1 |
		sed -E 's/[[:space:]]+$//'
}

# ---------------------------------------------------------------- resolve ----

resolve() {
	local key
	local val
	local from_file
	local in_var
	local in_val

	for key in "${!DEFAULTS[@]}"; do
		val="${DEFAULTS[$key]}"

		# ---------------------------------------------------------
		# 1. config.env
		# ---------------------------------------------------------

		from_file="$(cfg_read "$CONFIG_FILE" "$key")"

		if [ -n "$from_file" ]; then
			val="$from_file"
		fi

		# ---------------------------------------------------------
		# 2. workflow input
		# ---------------------------------------------------------
		#
		# "config" is deliberately ignored here.
		# It means "use config.env".
		#

		in_var="IN_${key}"
		in_val="${!in_var:-}"

		if [ -n "$in_val" ] && [ "$in_val" != "config" ]; then
			val="$in_val"
		fi

		CFG["$key"]="$val"
	done

	# -------------------------------------------------------------
	# Legacy configuration aliases
	# -------------------------------------------------------------

	local legacy
	local modern
	local lv
	local mv
	local modern_input

	for legacy in "${!ALIASES[@]}"; do
		modern="${ALIASES[$legacy]}"

		lv="$(cfg_read "$CONFIG_FILE" "$legacy")"

		[ -n "$lv" ] || continue

		case "$modern" in
			_LEGACY_*)
				CFG["$modern"]="$lv"
				;;

			*)
				mv="$(cfg_read "$CONFIG_FILE" "$modern")"
				modern_input="IN_${modern}"

				if [ -z "$mv" ] &&
					[ -z "${!modern_input:-}" ]; then

					CFG["$modern"]="$lv"

					debug \
						"legacy key ${legacy} -> ${modern}=${lv}"
				fi
				;;
		esac
	done
}

# --------------------------------------------- legacy compatibility bridge ----

apply_legacy_bridge() {
	local legacy_enable
	local legacy_patch

	legacy_enable="${CFG[_LEGACY_ENABLE_KERNELSU]:-}"
	legacy_patch="${CFG[_LEGACY_APPLY_KSU_PATCH]:-}"

	# Old config:
	#
	# ENABLE_KERNELSU=true
	# KERNELSU_TAG=...
	#
	# becomes:
	#
	# KSU_VARIANT=kernelsu

	if [ "${CFG[KSU_VARIANT]}" = "none" ] &&
		is_true "$legacy_enable"; then

		CFG[KSU_VARIANT]="kernelsu"

		warn \
			"legacy ENABLE_KERNELSU detected; treating it as KSU_VARIANT=kernelsu"

		warn \
			"Set KSU_VARIANT explicitly to select kernelsu-next, sukisu-ultra, resukisu, etc."
	fi

	# Old APPLY_KSU_PATCH=true means manual hooks.
	if is_true "$legacy_patch" &&
		[ "${CFG[KSU_HOOK_MODE]}" = "auto" ]; then

		CFG[KSU_HOOK_MODE]="manual"

		warn \
			"legacy APPLY_KSU_PATCH detected; treating it as KSU_HOOK_MODE=manual"
	fi

	unset \
		'CFG[_LEGACY_ENABLE_KERNELSU]' \
		'CFG[_LEGACY_APPLY_KSU_PATCH]'
}

# -------------------------------------------------------------- validation ----

validate_bool() {
	local key="$1"
	local value="${CFG[$key]}"

	case "$value" in
		true|false)
			;;

		*)
			warn \
				"config: ${key} must be true or false (got '${value}')"
			return 1
			;;
	esac
}

validate() {
	local errors=0

	_err() {
		warn "config: $*"
		errors=$((errors + 1))
	}

	# -------------------------------------------------------------
	# Required kernel parameters
	# -------------------------------------------------------------

	[ -n "${CFG[KERNEL_SOURCE]}" ] ||
		_err "KERNEL_SOURCE is required"

	[ -n "${CFG[KERNEL_SOURCE_BRANCH]}" ] ||
		_err "KERNEL_SOURCE_BRANCH is required"

	[ -n "${CFG[KERNEL_CONFIG]}" ] ||
		_err "KERNEL_CONFIG is required"

	[ -n "${CFG[KERNEL_IMAGE_NAME]}" ] ||
		_err "KERNEL_IMAGE_NAME is required"

	# -------------------------------------------------------------
	# Architecture
	# -------------------------------------------------------------

	case "${CFG[ARCH]}" in
		arm64|arm|x86_64|riscv)
			;;

		*)
			_err \
				"ARCH must be one of arm64/arm/x86_64/riscv (got '${CFG[ARCH]}')"
			;;
	esac

	# -------------------------------------------------------------
	# KernelSU variant
	# -------------------------------------------------------------

	case "${CFG[KSU_VARIANT]}" in
		none)
			;;

		kernelsu)
			;;

		kernelsu-next)
			;;

		sukisu-ultra)
			;;

		resukisu)
			;;

		rsuntk)
			;;

		backslashxx)
			;;

		*)
			_err \
				"unknown KSU_VARIANT '${CFG[KSU_VARIANT]}'"
			;;
	esac

	# -------------------------------------------------------------
	# Hook mode
	# -------------------------------------------------------------

	case "${CFG[KSU_HOOK_MODE]}" in
		auto|kprobes|manual|tracepoint|syscall|none)
			;;

		*)
			_err \
				"unknown KSU_HOOK_MODE '${CFG[KSU_HOOK_MODE]}'"
			;;
	esac

	# -------------------------------------------------------------
	# Boolean settings
	# -------------------------------------------------------------

	local bool_key

	for bool_key in \
		ADD_LOCALVERSION_TO_FILENAME \
		USE_CUSTOM_CLANG \
		USE_LLVM \
		ENABLE_GCC_ARM64 \
		ENABLE_GCC_ARM32 \
		USE_CUSTOM_GCC_64 \
		USE_CUSTOM_GCC_32 \
		ENABLE_SUSFS \
		ENABLE_PATH_UMOUNT \
		ENABLE_HIDE_STUFF \
		ENABLE_KPM \
		ADD_KPROBES_CONFIG \
		ADD_OVERLAYFS_CONFIG \
		DISABLE_LTO \
		DISABLE_CC_WERROR \
		USE_CUSTOM_ANYKERNEL3 \
		NEED_DTBO \
		BUILD_BOOT_IMG \
		ENABLE_CCACHE \
		REMOVE_UNUSED_PACKAGES
	do
		if ! validate_bool "$bool_key"; then
			errors=$((errors + 1))
		fi
	done

	# -------------------------------------------------------------
	# KernelSU dependencies
	# -------------------------------------------------------------

	if [ "${CFG[KSU_VARIANT]}" = "none" ]; then

		is_true "${CFG[ENABLE_SUSFS]}" &&
			_err \
				"ENABLE_SUSFS requires KSU_VARIANT other than 'none'"

		is_true "${CFG[ENABLE_PATH_UMOUNT]}" &&
			_err \
				"ENABLE_PATH_UMOUNT requires KSU_VARIANT other than 'none'"

		is_true "${CFG[ENABLE_HIDE_STUFF]}" &&
			_err \
				"ENABLE_HIDE_STUFF requires KSU_VARIANT other than 'none'"

		is_true "${CFG[ENABLE_KPM]}" &&
			_err \
				"ENABLE_KPM requires KSU_VARIANT=sukisu-ultra"
	fi

	# -------------------------------------------------------------
	# KPM
	# -------------------------------------------------------------

	if is_true "${CFG[ENABLE_KPM]}"; then

		[ "${CFG[KSU_VARIANT]}" = "sukisu-ultra" ] ||
			_err \
				"ENABLE_KPM is only supported with KSU_VARIANT=sukisu-ultra (got '${CFG[KSU_VARIANT]}')"

		[ "${CFG[ARCH]}" = "arm64" ] ||
			_err \
				"ENABLE_KPM requires ARCH=arm64"
	fi

	# -------------------------------------------------------------
	# Boot image
	# -------------------------------------------------------------

	if is_true "${CFG[BUILD_BOOT_IMG]}" &&
		[ -z "${CFG[SOURCE_BOOT_IMAGE]}" ]; then

		_err \
			"BUILD_BOOT_IMG=true requires SOURCE_BOOT_IMAGE"
	fi

	# -------------------------------------------------------------
	# Custom clang
	# -------------------------------------------------------------

	if is_true "${CFG[USE_CUSTOM_CLANG]}" &&
		[ -z "${CFG[CUSTOM_CLANG_SOURCE]}" ]; then

		_err \
			"USE_CUSTOM_CLANG=true requires CUSTOM_CLANG_SOURCE"
	fi

	# -------------------------------------------------------------
	# Custom AnyKernel3
	# -------------------------------------------------------------

	if is_true "${CFG[USE_CUSTOM_ANYKERNEL3]}" &&
		[ -z "${CFG[CUSTOM_ANYKERNEL3_SOURCE]}" ]; then

		_err \
			"USE_CUSTOM_ANYKERNEL3=true requires CUSTOM_ANYKERNEL3_SOURCE"
	fi

	# -------------------------------------------------------------
	# GCC consistency
	# -------------------------------------------------------------

	if is_true "${CFG[USE_CUSTOM_GCC_64]}" &&
		[ -z "${CFG[CUSTOM_GCC_64_SOURCE]}" ]; then

		_err \
			"USE_CUSTOM_GCC_64=true requires CUSTOM_GCC_64_SOURCE"
	fi

	if is_true "${CFG[USE_CUSTOM_GCC_32]}" &&
		[ -z "${CFG[CUSTOM_GCC_32_SOURCE]}" ]; then

		_err \
			"USE_CUSTOM_GCC_32=true requires CUSTOM_GCC_32_SOURCE"
	fi

	# -------------------------------------------------------------
	# Final result
	# -------------------------------------------------------------

	if [ "$errors" -ne 0 ]; then
		die \
			"${errors} configuration error(s); fix ${CONFIG_FILE} or the workflow inputs"
	fi
}

# ------------------------------------------------------------------- device ----

derive_device() {
	local device

	device="$(
		printf '%s' "${CFG[KERNEL_CONFIG]}" |
			sed \
				's!.*/!!;
				 s/_defconfig$//;
				 s/_user$//;
				 s/-perf$//'
	)"

	[ -n "${CFG[KERNEL_NAME]}" ] &&
		device="${CFG[KERNEL_NAME]}"

	printf '%s' "$device"
}

# ------------------------------------------------------------------- summary ----

print_configuration() {
	summary "### Build configuration"
	summary ""
	summary "| Item | Value |"
	summary "| --- | --- |"

	group "Resolved configuration"

	local key

	for key in $(printf '%s\n' "${!CFG[@]}" | sort); do

		printf \
			'  %-32s = %s\n' \
			"$key" \
			"${CFG[$key]}"

		export_env \
			"$key" \
			"${CFG[$key]}"
	done

	endgroup
}

# ------------------------------------------------------------------- main -------

declare -A CFG

resolve
apply_legacy_bridge
validate

DEVICE="$(derive_device)"

CFG[DEVICE]="$DEVICE"

print_configuration

export_env \
	BUILD_TIME \
	"$(TZ="${BUILD_TZ:-Asia/Shanghai}" date '+%Y%m%d%H%M')"

ok "configuration resolved (device: ${DEVICE})"
