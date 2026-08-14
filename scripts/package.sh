#!/usr/bin/env bash

# Package build output: AnyKernel3 flashable zip and, optionally, a boot image.

set -euo pipefail

# shellcheck source=scripts/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

KERNEL_DIR=${KERNEL_DIR:?KERNEL_DIR must be set}
WORKSPACE=${WORKSPACE:-$(cd "${KERNEL_DIR}/.." && pwd)}
ARCH=${ARCH:-arm64}

BOOT_OUT="${KERNEL_DIR}/out/arch/${ARCH}/boot"
AK3="${WORKSPACE}/AnyKernel3"

# ------------------------------------------------------------- AnyKernel3 ---

make_anykernel3() {
	group "Building AnyKernel3 package"

	rm -rf "$AK3"

	if is_true "${USE_CUSTOM_ANYKERNEL3:-false}"; then
		local src=${CUSTOM_ANYKERNEL3_SOURCE:?CUSTOM_ANYKERNEL3_SOURCE required}

		case "$src" in
			*.tar.gz|*.tgz)
				fetch "$src" "${WORKSPACE}/ak3.tar.gz"
				extract_archive "${WORKSPACE}/ak3.tar.gz" "$AK3"
				;;

			*.zip)
				fetch "$src" "${WORKSPACE}/ak3.zip"
				extract_archive "${WORKSPACE}/ak3.zip" "$AK3"
				;;

			*git*)
				if [ -n "${CUSTOM_ANYKERNEL3_BRANCH:-}" ]; then
					retry 3 git clone -q \
						--depth=1 \
						-b "${CUSTOM_ANYKERNEL3_BRANCH}" \
						"$src" "$AK3"
				else
					retry 3 git clone -q \
						--depth=1 \
						"$src" "$AK3"
				fi

				[ -d "$AK3" ] ||
					die "failed to clone ${src}"
				;;

			*)
				fetch "$src" "${WORKSPACE}/ak3.zip"
				extract_archive "${WORKSPACE}/ak3.zip" "$AK3"
				;;
		esac
	else
		retry 3 git clone -q \
			--depth=1 \
			https://github.com/osm0sis/AnyKernel3 \
			"$AK3" ||
			die "failed to clone AnyKernel3"
	fi

	# ---------------------------------------------------------
	# Known-good AnyKernel3 configuration for Motorola kiev.
	# This configuration is intentionally kept explicit.
	# ---------------------------------------------------------

	cat > "${AK3}/anykernel.sh" <<'EOF'
### AnyKernel3 Ramdisk Mod Script

## osm0sis @ xda-developers
### AnyKernel setup
properties() { '
kernel.string=Custom Kernel avec SukiSU-Ultra pour Motorola One 5G Ace
do.devicecheck=1
do.modules=1
do.systemless=1
do.cleanup=1
do.cleanuponabort=1
device.name1=kiev
device.name2=XT2113-2
device.name3=kiev_retde
device.name4=kiev_t
device.name5=
supported.versions=
supported.patchlevels=
supported.vendorpatchlevels=
'; } # end properties

### AnyKernel install
boot_attributes() {
set_perm_recursive 0 0 755 644 $RAMDISK/*
set_perm_recursive 0 0 750 750 $RAMDISK/init* $RAMDISK/sbin;
} # end attributes

# boot shell variables
BLOCK=/dev/block/by-name/boot;
IS_SLOT_DEVICE=1;
RAMDISK_COMPRESSION=auto;
PATCH_VBMETA_FLAG=auto;

. tools/ak3-core.sh;
split_boot;
EOF

	[ -f "${AK3}/anykernel.sh" ] ||
		die "failed to create ${AK3}/anykernel.sh"

	# ---------------------------------------------------------
	# Copy compiled kernel image
	# ---------------------------------------------------------

	[ -n "${KERNEL_IMAGE_NAME:-}" ] ||
		die "KERNEL_IMAGE_NAME is not set"

	[ -f "${BOOT_OUT}/${KERNEL_IMAGE_NAME}" ] ||
		die "kernel image missing at ${BOOT_OUT}/${KERNEL_IMAGE_NAME}"

	cp \
		"${BOOT_OUT}/${KERNEL_IMAGE_NAME}" \
		"${AK3}/" ||
		die "failed to copy kernel image into AnyKernel3"

	# ---------------------------------------------------------
	# Optional DTBO
	# ---------------------------------------------------------

	if is_true "${CHECK_DTBO_IS_OK:-false}"; then
		[ -f "${BOOT_OUT}/dtbo.img" ] ||
			die "CHECK_DTBO_IS_OK=true but ${BOOT_OUT}/dtbo.img is missing"

		cp \
			"${BOOT_OUT}/dtbo.img" \
			"${AK3}/" ||
			die "failed to copy dtbo.img into AnyKernel3"
	fi

	# ---------------------------------------------------------
	# Remove repository-only files
	# ---------------------------------------------------------

	rm -rf \
		"${AK3}/.git" \
		"${AK3}/.github" \
		"${AK3}/README.md"

	ok "AnyKernel3 package assembled"
	ok "AnyKernel3 target: kiev / XT2113-2"
	ok "AnyKernel3 BLOCK: /dev/block/by-name/boot"
	ok "AnyKernel3 slot device: 1"

	endgroup
}

# ------------------------------------------------------------- boot image ---

make_boot_image() {
	is_true "${BUILD_BOOT_IMG:-false}" || return 0

	group "Repacking boot image"

	local tools="${WORKSPACE}/tools"

	[ -f "${tools}/unpack_bootimg.py" ] ||
		die "unpack_bootimg.py not found at ${tools}"

	[ -f "${tools}/mkbootimg.py" ] ||
		die "mkbootimg.py not found at ${tools}"

	fetch \
		"${SOURCE_BOOT_IMAGE:?SOURCE_BOOT_IMAGE required}" \
		"${WORKSPACE}/boot-source.img"

	cd "$WORKSPACE"

	# ---------------------------------------------------------
	# Read original boot image arguments.
	# ---------------------------------------------------------

	local fmt

	fmt=$(
		python3 "${tools}/unpack_bootimg.py" \
			--boot_img boot-source.img \
			--format mkbootimg
	) || die "failed to read the source boot image"

	info "source boot image args: ${fmt}"

	# ---------------------------------------------------------
	# Unpack source boot image.
	# ---------------------------------------------------------

	python3 "${tools}/unpack_bootimg.py" \
		--boot_img boot-source.img \
		>/dev/null ||
		die "failed to unpack the source boot image"

	# ---------------------------------------------------------
	# Stage the newly compiled kernel.
	# ---------------------------------------------------------

	[ -n "${KERNEL_IMAGE_NAME:-}" ] ||
		die "KERNEL_IMAGE_NAME is not set"

	[ -f "${BOOT_OUT}/${KERNEL_IMAGE_NAME}" ] ||
		die "kernel image missing at ${BOOT_OUT}/${KERNEL_IMAGE_NAME}"

	[ -d "${WORKSPACE}/out" ] ||
		die "unpacked boot output directory not found"

	cp \
		"${BOOT_OUT}/${KERNEL_IMAGE_NAME}" \
		"${WORKSPACE}/out/kernel" ||
		die "could not stage the new kernel into the unpacked boot image"

	# ---------------------------------------------------------
	# IMPORTANT:
	#
	# unpack_bootimg.py returns a shell-style command line.
	#
	# Example:
	#
	# --cmdline 'androidboot.console=ttyMSM0 androidboot.hardware=qcom ...'
	#
	# We MUST preserve the entire --cmdline as ONE argument.
	#
	# Directly using:
	#
	#     python3 mkbootimg.py $fmt
	#
	# breaks the quoted cmdline into many arguments.
	#
	# We therefore let Bash parse the generated command line once
	# into an array and then pass each argument safely.
	# ---------------------------------------------------------

	local -a mkboot_args=()

	eval "mkboot_args=( ${fmt} )"

	[ "${#mkboot_args[@]}" -gt 0 ] ||
		die "mkbootimg argument list is empty"

	info "rebuilding boot image with ${#mkboot_args[@]} arguments"

	python3 "${tools}/mkbootimg.py" \
		"${mkboot_args[@]}" \
		-o "${WORKSPACE}/boot.img" ||
		die "mkbootimg failed"

	[ -s "${WORKSPACE}/boot.img" ] ||
		die "boot.img was not produced"

	ok "boot.img built ($(du -h "${WORKSPACE}/boot.img" | cut -f1))"

	export_env MAKE_BOOT_IMAGE_IS_OK true

	endgroup
}

# ------------------------------------------------------------- summary ---

write_summary() {
	summary ""
	summary "### Build artifacts"
	summary ""
	summary "| Artifact | Size |"
	summary "| --- | --- |"

	local f

	for f in \
		"${BOOT_OUT}/${KERNEL_IMAGE_NAME}" \
		"${BOOT_OUT}/dtbo.img" \
		"${WORKSPACE}/boot.img"
	do
		if [ -f "$f" ]; then
			summary "| \`$(basename "$f")\` | $(du -h "$f" | cut -f1) |"
		fi
	done

	if [ -d "$AK3" ]; then
		summary "| \`AnyKernel3\` | $(du -sh "$AK3" | cut -f1) |"
	fi

	summary ""
}

# ------------------------------------------------------------- main ---

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
	case "${1:-all}" in
		anykernel3)
			make_anykernel3
			;;

		bootimg)
			make_boot_image
			;;

		all)
			make_anykernel3
			make_boot_image
			write_summary
			;;

		*)
			die "unknown package step '$1'"
			;;
	esac
fi
