#!/usr/bin/env bash

# Prepare the defconfig and compile the kernel.

set -euo pipefail

# shellcheck source=scripts/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# shellcheck source=scripts/kernelsu.sh
. "$(dirname "${BASH_SOURCE[0]}")/kernelsu.sh"

# shellcheck source=scripts/patches.sh
. "$(dirname "${BASH_SOURCE[0]}")/patches.sh"

KERNEL_DIR=${KERNEL_DIR:?KERNEL_DIR must be set}
WORKSPACE=${WORKSPACE:-$(cd "${KERNEL_DIR}/.." && pwd)}
ARCH=${ARCH:-arm64}
OUT="${KERNEL_DIR}/out"

DEFCONFIG_PATH="${KERNEL_DIR}/arch/${ARCH}/configs/${KERNEL_CONFIG}"

# ------------------------------------------------------------- defconfig ---

prepare_defconfig() {
	group "Preparing defconfig"

	[ -f "$DEFCONFIG_PATH" ] || die "defconfig not found: arch/${ARCH}/configs/${KERNEL_CONFIG}
Available: $(ls "${KERNEL_DIR}/arch/${ARCH}/configs/" | head -20 | tr '\n' ' ')"

	cp "$DEFCONFIG_PATH" "${WORKSPACE}/defconfig.orig"

	local kver
	kver=$(kernel_version "$KERNEL_DIR" || echo "0.0")

	if [ "${KSU_VARIANT:-none}" != "none" ]; then
		kconf_enable "$DEFCONFIG_PATH" CONFIG_KSU

		ksu_hook_configs \
			"${KSU_VARIANT}" \
			"${KSU_HOOK_MODE:-auto}" \
			"$DEFCONFIG_PATH" \
			"$kver"

		if is_true "${ENABLE_SUSFS:-false}"; then
			susfs_defconfig "$DEFCONFIG_PATH"
		fi

		if is_true "${ENABLE_KPM:-false}"; then
			kconf_set_many "$DEFCONFIG_PATH" \
				CONFIG_KPM=y \
				CONFIG_KALLSYMS=y \
				CONFIG_KALLSYMS_ALL=y
		fi
	fi

	# Overlayfs backs KernelSU's module mounts and system-partition writes.
	if is_true "${ADD_OVERLAYFS_CONFIG:-false}"; then
		kconf_enable "$DEFCONFIG_PATH" CONFIG_OVERLAY_FS
	fi

	# Standalone kprobes configuration.
	if is_true "${ADD_KPROBES_CONFIG:-false}"; then
		kconf_set_many "$DEFCONFIG_PATH" \
			CONFIG_MODULES=y \
			CONFIG_KPROBES=y \
			CONFIG_HAVE_KPROBES=y \
			CONFIG_KPROBE_EVENTS=y
	fi

	if is_true "${DISABLE_LTO:-false}"; then
		kconf_set_many "$DEFCONFIG_PATH" \
			CONFIG_LTO=n \
			CONFIG_LTO_CLANG=n \
			CONFIG_LTO_CLANG_FULL=n \
			CONFIG_LTO_CLANG_THIN=n \
			CONFIG_THINLTO=n \
			CONFIG_LTO_NONE=y
	fi

	if is_true "${DISABLE_CC_WERROR:-false}"; then
		kconf_disable "$DEFCONFIG_PATH" CONFIG_CC_WERROR
	fi

	# Free-form extras: one CONFIG_x=y per line, or space separated.
	if [ -n "${EXTRA_DEFCONFIG:-}" ]; then
		local kv

		# shellcheck disable=SC2086
		for kv in $(printf '%s' "$EXTRA_DEFCONFIG" | tr '\n' ' '); do
			[ -n "$kv" ] || continue

			case "$kv" in
				*=*)
					kconf_set \
						"$DEFCONFIG_PATH" \
						"${kv%%=*}" \
						"${kv#*=}"
					;;
				*)
					warn "ignoring malformed EXTRA_DEFCONFIG entry '${kv}' (want CONFIG_X=y)"
					;;
			esac
		done
	fi

	# Stable LOCALVERSION for predictable artifact names.
	if [ -n "${KERNEL_NAME:-}" ]; then
		kconf_set \
			"$DEFCONFIG_PATH" \
			CONFIG_LOCALVERSION \
			"\"-${KERNEL_NAME}\""

		if [ -f "${KERNEL_DIR}/scripts/setlocalversion" ]; then
			sed -i 's/-dirty//g' \
				"${KERNEL_DIR}/scripts/setlocalversion"
		fi
	fi

	info "defconfig changes:"

	diff -u \
		"${WORKSPACE}/defconfig.orig" \
		"$DEFCONFIG_PATH" |
		sed -n '4,$p' |
		sed 's/^/    /' ||
		true

	endgroup
}

# ----------------------------------------------------------------- build ---

make_args() {
	printf '%s' "O=out ARCH=${ARCH}"

	[ -n "${CUSTOM_CMDS:-}" ] && printf ' %s' "$CUSTOM_CMDS"
	[ -n "${EXTRA_CMDS:-}" ] && printf ' %s' "$EXTRA_CMDS"
	[ -n "${GCC_64:-}" ] && printf ' %s' "$GCC_64"
	[ -n "${GCC_32:-}" ] && printf ' %s' "$GCC_32"

	if is_true "${USE_LLVM:-false}"; then
		printf ' LLVM=1 LLVM_IAS=1'

		[ -n "${GCC_64:-}" ] ||
			printf ' CROSS_COMPILE=aarch64-linux-gnu-'
	fi
}

setup_ccache() {
	if ! is_true "${ENABLE_CCACHE:-true}"; then
		info "ccache disabled"
		unset CCACHE_DIR CCACHE_PREFIX
		return 0
	fi

	if ! command -v ccache >/dev/null 2>&1; then
		warn "ENABLE_CCACHE=true but ccache is not installed; building without ccache"
		unset CCACHE_DIR CCACHE_PREFIX
		return 0
	fi

	export CCACHE_DIR="${CCACHE_DIR:-${WORKSPACE}/.ccache}"

	mkdir -p "$CCACHE_DIR"

	# Kbuild continues to see CC=clang. ccache is inserted through
	# CCACHE_PREFIX instead of making CC a multi-word command.
	export CCACHE_PREFIX="${CCACHE_PREFIX:-ccache}"

	# Keep ccache's own cache configuration predictable in CI.
	if ccache --version >/dev/null 2>&1; then
		ccache --set-config=compiler_check="${CCACHE_COMPILERCHECK:-%compiler% -dumpmachine; %compiler% -dumpversion}" \
			>/dev/null 2>&1 || true

		ccache --set-config=base_dir="${KERNEL_DIR}" \
			>/dev/null 2>&1 || true

		ccache --zero-stats \
			>/dev/null 2>&1 || true
	fi

	info "ccache enabled"
	info "cache directory: ${CCACHE_DIR}"

	if command -v ccache >/dev/null 2>&1; then
		ccache --show-config \
			2>/dev/null |
			grep -E '^(cache_dir|compiler_check|base_dir)' |
			sed 's/^/    /' ||
			true
	fi
}

build_kernel() {
	group "Building kernel"

	export PATH="${CLANG_PATH:-}:${PATH}"
	export KBUILD_BUILD_HOST="${KBUILD_BUILD_HOST:-Github-Action}"
	export KBUILD_BUILD_USER="${KBUILD_BUILD_USER:-kernelsu-action}"

	# DISABLE_LTO is an action/configuration flag, not a Kbuild compiler
	# variable. Do not leak the string "false" into compiler invocations.
	unset DISABLE_LTO

	# Custom manager signature, when supplied.
	if [ -n "${KSU_EXPECTED_SIZE:-}" ] &&
		[ -n "${KSU_EXPECTED_HASH:-}" ]; then
		export KSU_EXPECTED_SIZE KSU_EXPECTED_HASH
		info "using custom manager signature (size=${KSU_EXPECTED_SIZE})"
	fi

	setup_ccache

	local args
	args=$(make_args)

	cd "$KERNEL_DIR"

	# Always keep CC as the compiler itself.
	local cc="${CC:-clang}"

	info "compiler: ${cc}"
	info "make arguments: ${args}"
	info "defconfig: ${KERNEL_CONFIG}"

	# shellcheck disable=SC2086
	make -j"$(nproc --all)" \
		CC="$cc" \
		$args \
		"${KERNEL_CONFIG}" ||
		die "defconfig generation failed"

	info "make ${args}"

	# shellcheck disable=SC2086
	make -j"$(nproc --all)" \
		CC="$cc" \
		$args ||
		die "kernel build failed"

	if is_true "${ENABLE_CCACHE:-true}" &&
		command -v ccache >/dev/null 2>&1; then
		info "ccache statistics:"
		ccache --show-stats || true
	fi

	endgroup
}

# --------------------------------------------------------------- verify ---

check_output() {
	group "Checking build output"

	local boot="${OUT}/arch/${ARCH}/boot"
	local configured_image="${KERNEL_IMAGE_NAME:-}"

	[ -d "$boot" ] ||
		die "kernel boot output directory not found: ${boot}"

	info "kernel boot directory: ${boot}"

	# First use the configured image name if it exists.
	local image=""

	if [ -n "$configured_image" ] &&
		[ -f "${boot}/${configured_image}" ]; then
		image="${boot}/${configured_image}"
	else
		# Some vendor kernels ignore the generic KERNEL_IMAGE_NAME expected
		# by the workflow and produce a different image. Detect the actual
		# Kbuild output instead of failing after a successful compilation.
		local candidate

		for candidate in \
			Image.gz-dtb \
			Image.gz \
			Image \
			zImage-dtb \
			zImage \
			uImage
		do
			if [ -f "${boot}/${candidate}" ]; then
				image="${boot}/${candidate}"
				break
			fi
		done
	fi

	[ -n "$image" ] || die "no kernel image found in ${boot}
Built files: $(ls "$boot" 2>/dev/null | tr '\n' ' ')
Configured KERNEL_IMAGE_NAME: ${configured_image:-<unset>}"

	# Publish the image name actually produced by this kernel.
	# This is important because package.sh runs in a later GitHub Actions
	# step and therefore needs the resolved value through GITHUB_ENV.
	local actual_image
	actual_image=$(basename "$image")

	if [ "$actual_image" != "$configured_image" ]; then
		warn "configured KERNEL_IMAGE_NAME='${configured_image:-<unset>}' was not produced"
		warn "detected kernel image '${actual_image}' instead"
		export_env KERNEL_IMAGE_NAME "$actual_image"
	else
		export_env KERNEL_IMAGE_NAME "$configured_image"
	fi

	ok "kernel image detected: ${actual_image}"
	ok "kernel image path: ${image}"

	export_env CHECK_FILE_IS_OK true

	if is_true "${NEED_DTBO:-false}"; then
		[ -f "${boot}/dtbo.img" ] ||
			die "NEED_DTBO=true but ${boot}/dtbo.img was not produced"

		export_env CHECK_DTBO_IS_OK true
		ok "dtbo.img present"
	fi

	# KPM modifies the final kernel image, so it must run after compilation
	# and before packaging.
	if is_true "${ENABLE_KPM:-false}"; then
		kpm_patch_image "$image"
	fi

	# Record the version actually generated by Kbuild.
	if [ -f "${OUT}/include/generated/utsrelease.h" ]; then
		local rel

		rel=$(
			sed -nE \
				's/.*UTS_RELEASE[[:space:]]+"([^"]+)".*/\1/p' \
				"${OUT}/include/generated/utsrelease.h"
		)

		export_env KERNEL_RELEASE "$rel"
		ok "kernel release: ${rel}"
		summary "| Kernel release | \`${rel}\` |"
	fi

	endgroup
}

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
	case "${1:-all}" in
		defconfig)
			prepare_defconfig
			;;

		compile)
			build_kernel
			;;

		check)
			check_output
			;;

		all)
			prepare_defconfig
			build_kernel
			check_output
			;;

		*)
			die "unknown build step '$1'"
			;;
	esac
fi
