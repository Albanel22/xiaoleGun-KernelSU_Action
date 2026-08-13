#!/usr/bin/env bash

# Kernel source patching:
# SUSFS, path_umount backport, hide_stuff, manual hooks and KPM.
#
# All operations are designed to be idempotent where possible. A patch that
# is already present is skipped instead of being applied twice.

set -euo pipefail

# shellcheck source=scripts/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

KERNEL_DIR=${KERNEL_DIR:?KERNEL_DIR must point at the kernel source tree}
WORKSPACE=${WORKSPACE:-$(cd "${KERNEL_DIR}/.." && pwd)}

# Resolve paths from this script location rather than $PWD.
REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

# ====================================================================== SUSFS

susfs_branch_for() {
	case "$1" in
		4.9)  echo "kernel-4.9" ;;
		4.14) echo "kernel-4.14" ;;
		4.19) echo "kernel-4.19" ;;
		5.4)  echo "kernel-5.4" ;;
		5.10) echo "gki-android12-5.10" ;;
		5.15) echo "gki-android13-5.15" ;;
		6.1)  echo "gki-android14-6.1" ;;
		6.6)  echo "gki-android15-6.6" ;;
		6.12) echo "gki-android16-6.12" ;;
		*)    echo "" ;;
	esac
}

susfs_is_bundled() {
	local bundled=${KSU_SUSFS_BUNDLED_REFS:--}
	local ref=${KSU_REF_RESOLVED:-}
	local r

	# Explicitly configured bundled refs.
	if [ "$bundled" != "-" ]; then
		for r in $bundled; do
			[ "$r" = "$ref" ] && return 0
		done
	fi

	# Authoritative fallback: inspect the actual KernelSU tree.
	local ksu_dir="${KERNEL_DIR}/${KSU_DIR:-KernelSU}"

	[ -d "$ksu_dir" ] || return 1

	grep -rEq \
		'CONFIG_KSU_SUSFS|^[[:space:]]*config[[:space:]]+KSU_SUSFS' \
		"$ksu_dir" 2>/dev/null
}

susfs_apply() {
	local repo=${SUSFS_REPO:-https://gitlab.com/simonpunk/susfs4ksu.git}
	local branch=${SUSFS_BRANCH:-auto}
	local kver

	kver=$(kernel_version "$KERNEL_DIR") \
		|| die "cannot read kernel version from ${KERNEL_DIR}/Makefile"

	group "Applying SUSFS"

	if [ "$branch" = "auto" ]; then
		branch=$(susfs_branch_for "$kver")

		if [ -z "$branch" ]; then
			die "no SUSFS branch is known for kernel ${kver}; set SUSFS_BRANCH explicitly"
		fi

		info "kernel ${kver} -> SUSFS branch '${branch}'"
	fi

	ref_exists "$repo" "$branch" || {
		die "SUSFS repository has no branch '${branch}'"
	}

	local susfs_dir="${WORKSPACE}/susfs4ksu"
	rm -rf "$susfs_dir"

	retry 3 git clone -q --depth=1 -b "$branch" \
		"$repo" "$susfs_dir" \
		|| die "failed to clone ${repo} @ ${branch}"

	local kp="${susfs_dir}/kernel_patches"

	[ -d "$kp" ] || die \
		"unexpected susfs4ksu layout: ${kp} is missing"

	# ---------------------------------------------------------------- sources

	info "copying SUSFS sources into kernel tree"

	cp -v "${kp}/fs/"*.c \
		"${KERNEL_DIR}/fs/" 2>/dev/null || true

	cp -v "${kp}/include/linux/"*.h \
		"${KERNEL_DIR}/include/linux/" 2>/dev/null || true

	# --------------------------------------------------------------- kernel patch

	local kernel_patch="${kp}/50_add_susfs_in_${branch}.patch"

	if [ ! -f "$kernel_patch" ]; then
		kernel_patch=$(find "$kp" -maxdepth 1 \
			-type f \
			-name '50_add_susfs_in_*.patch' \
			-print -quit)
	fi

	[ -n "$kernel_patch" ] &&
	[ -f "$kernel_patch" ] ||
		die "no 50_add_susfs_in_*.patch found in ${kp}"

	# Do not apply the same patch twice.
	if (cd "$KERNEL_DIR" && patch -p1 --dry-run < "$kernel_patch" >/dev/null 2>&1); then
		(
			cd "$KERNEL_DIR"
			apply_patch "$kernel_patch" 1
		) || die "SUSFS kernel patch failed to apply"
	else
		info "SUSFS kernel patch appears to be already applied; skipping"
	fi

	# ---------------------------------------------------------- KernelSU patch

	local ksu_dir="${KERNEL_DIR}/${KSU_DIR:-KernelSU}"
	local ksu_patch="${kp}/KernelSU/10_enable_susfs_for_ksu.patch"

	if susfs_is_bundled; then
		info "${KSU_NAME:-selected KernelSU variant} already bundles SUSFS; skipping KernelSU-side patch"

	elif [ ! -d "$ksu_dir" ]; then
		warn "KernelSU directory not found at ${ksu_dir}; skipping KernelSU-side SUSFS patch"

	elif [ ! -f "$ksu_patch" ]; then
		warn "SUSFS branch '${branch}' does not contain KernelSU/10_enable_susfs_for_ksu.patch"

	elif (
		cd "$ksu_dir"
		patch -p1 --dry-run < "$ksu_patch" >/dev/null 2>&1
	); then
		(
			cd "$ksu_dir"
			apply_patch "$ksu_patch" 1
		) || die "KernelSU-side SUSFS patch failed"

	else
		info "KernelSU-side SUSFS patch appears to be already applied; skipping"
	fi

	# --------------------------------------------------------------- version

	local sv="unknown"

	if [ -f "${KERNEL_DIR}/include/linux/susfs.h" ]; then
		sv=$(
			sed -nE \
				's/.*SUSFS_VERSION[[:space:]]+"([^"]+)".*/\1/p' \
				"${KERNEL_DIR}/include/linux/susfs.h" |
			head -n1
		)

		[ -n "$sv" ] || sv="unknown"
	fi

	export_env SUSFS_VERSION "$sv"
	export_env SUSFS_BRANCH_RESOLVED "$branch"

	ok "SUSFS ${sv} applied from branch ${branch}"
	summary "| SUSFS | \`${sv}\` (branch \`${branch}\`) |"

	endgroup
}

susfs_defconfig() {
	local defconfig=$1
	local ksu_dir="${KERNEL_DIR}/${KSU_DIR:-KernelSU}"

	# Discover the actual SUSFS symbols from the patched tree.
	# This avoids hardcoding a symbol list because SUSFS v1/v2 branches differ.

	local syms=""

	if [ -d "$ksu_dir" ]; then
		syms=$(
			grep -rhoE \
				'^[[:space:]]*config[[:space:]]+KSU_SUSFS[A-Z_]*' \
				"$ksu_dir" 2>/dev/null |
			awk '{print $2}' |
			sort -u || true
		)
	fi

	# Some branches expose Kconfig from the kernel tree instead.
	if [ -z "$syms" ]; then
		syms=$(
			grep -rhoE \
				'^[[:space:]]*config[[:space:]]+KSU_SUSFS[A-Z_]*' \
				"${KERNEL_DIR}/fs" \
				"${KERNEL_DIR}/drivers" 2>/dev/null |
			awk '{print $2}' |
			sort -u || true
		)
	fi

	if [ -z "$syms" ]; then
		die "no KSU_SUSFS Kconfig symbols found after SUSFS integration"
	fi

	local s
	local enabled=0

	for s in $syms; do
		case "$s" in
			KSU_SUSFS_SUS_SU|KSU_SUSFS_SUS_OVERLAYFS)
				# These options are intentionally disabled in the reference
				# configurations because they can conflict with the selected
				# KernelSU implementation.
				kconf_disable "$defconfig" "CONFIG_${s}"
				;;

			*)
				kconf_enable "$defconfig" "CONFIG_${s}"
				enabled=$((enabled + 1))
				;;
		esac
	done

	ok "enabled ${enabled} SUSFS options discovered from Kconfig"
	debug "SUSFS symbols: $(printf '%s ' $syms)"
}

# =============================================================== path_umount

path_umount_apply() {
	local ns="${KERNEL_DIR}/fs/namespace.c"

	group "Backporting path_umount()"

	local kver
	kver=$(kernel_version "$KERNEL_DIR") \
		|| die "cannot read kernel version"

	if ver_ge "$kver" "5.9"; then
		info "kernel ${kver} already provides path_umount(); nothing to do"
		endgroup
		return 0
	fi

	[ -f "$ns" ] || die "fs/namespace.c not found"

	if grep -qE '^[[:space:]]*(static[[:space:]]+)?int[[:space:]]+path_umount[[:space:]]*\(' "$ns"; then
		info "path_umount() already exists; nothing to do"
		endgroup
		return 0
	fi

	local anchor='Now umount can handle mount points as well as block devices'

	grep -q "$anchor" "$ns" || {
		die "could not find path_umount insertion point in fs/namespace.c"
	}

	local snippet
	snippet=$(mktemp)

	# can_umount() was introduced together with path_umount().
	if ! grep -qE '^[[:space:]]*static[[:space:]]+int[[:space:]]+can_umount[[:space:]]*\(' "$ns"; then
		cat >"$snippet" <<'EOF'
static int can_umount(const struct path *path, int flags)
{
	struct mount *mnt = real_mount(path->mnt);

	if (flags & ~(MNT_FORCE | MNT_DETACH | MNT_EXPIRE | UMOUNT_NOFOLLOW))
		return -EINVAL;
	if (!may_mount())
		return -EPERM;
	if (path->dentry != path->mnt->mnt_root)
		return -EINVAL;
	if (!check_mnt(mnt))
		return -EINVAL;
	if (mnt->mnt.mnt_flags & MNT_LOCKED)
		return -EINVAL;
	if (flags & MNT_FORCE && !capable(CAP_SYS_ADMIN))
		return -EPERM;

	return 0;
}

EOF
	fi

	cat >>"$snippet" <<'EOF'
int path_umount(struct path *path, int flags)
{
	struct mount *mnt = real_mount(path->mnt);
	int ret;

	ret = can_umount(path, flags);
	if (!ret)
		ret = do_umount(mnt, flags);

	/* We must not call path_put(), as that would clear mnt_expiry_mark. */
	dput(path->dentry);
	mntput_no_expire(mnt);

	return ret;
}

EOF

	local lineno
	lineno=$(grep -n "$anchor" "$ns" | head -n1 | cut -d: -f1)

	local start=$lineno

	while [ "$start" -gt 1 ]; do
		if sed -n "${start}p" "$ns" | grep -q '/\*'; then
			break
		fi
		start=$((start - 1))
	done

	local tmp
	tmp=$(mktemp)

	head -n "$((start - 1))" "$ns" >"$tmp"
	cat "$snippet" >>"$tmp"
	tail -n "+${start}" "$ns" >>"$tmp"

	mv "$tmp" "$ns"
	rm -f "$snippet"

	grep -qE '^[[:space:]]*int path_umount[[:space:]]*\(' "$ns" ||
		die "path_umount() insertion failed"

	ok "path_umount() backported into fs/namespace.c (kernel ${kver})"
	summary "| path_umount | backported (kernel ${kver}) |"

	endgroup
}

# ================================================================ extra patches

SUKISU_PATCH_REPO=${SUKISU_PATCH_REPO:-https://github.com/ShirkNeko/SukiSU_patch.git}

sukisu_patch_dir() {
	local dir="${WORKSPACE}/SukiSU_patch"

	if [ ! -d "$dir" ]; then
		retry 3 git clone -q --depth=1 \
			"$SUKISU_PATCH_REPO" "$dir" ||
			die "failed to clone ${SUKISU_PATCH_REPO}"
	fi

	printf '%s' "$dir"
}

hide_stuff_apply() {
	group "Applying hide_stuff"

	local dir
	dir=$(sukisu_patch_dir)

	local patch="${dir}/69_hide_stuff.patch"

	if [ ! -f "$patch" ]; then
		warn "69_hide_stuff.patch not found; skipping"
		endgroup
		return 0
	fi

	if (
		cd "$KERNEL_DIR"
		patch -p1 --dry-run < "$patch" >/dev/null 2>&1
	); then
		(
			cd "$KERNEL_DIR"
			apply_patch "$patch" 1
		) || warn "hide_stuff patch failed; continuing"
	else
		info "hide_stuff patch already applied or not applicable; skipping"
	fi

	endgroup
}

# ================================================================ manual hooks

hooks_patch_apply() {
	local variant=${KSU_VARIANT:-none}
	local kver

	kver=$(kernel_version "$KERNEL_DIR") || return 0

	group "Applying manual syscall hooks (kernel ${kver})"

	# ----------------------------------------------------------- ReSukiSU

	if [ "$variant" = "resukisu" ]; then
		local dir="${WORKSPACE}/ReSukiSU_Patches"

		if [ ! -d "$dir" ]; then
			retry 3 git clone -q --depth=1 \
				https://github.com/ReSukiSU/ReSukiSU_Patches.git \
				"$dir" || true
		fi

		local p="${dir}/scope-minimized/kernel-${kver}.patch"

		if [ -f "$p" ]; then
			if (
				cd "$KERNEL_DIR"
				patch -p1 --dry-run < "$p" >/dev/null 2>&1
			); then
				(
					cd "$KERNEL_DIR"
					apply_patch "$p" 1
				) || die "ReSukiSU hook patch failed"

				ok "ReSukiSU hooks applied"
				endgroup
				return 0
			else
				info "ReSukiSU hook patch already applied or not applicable"
			fi
		else
			info "ReSukiSU has no scope-minimized patch for kernel ${kver}"
		fi
	fi

	# ----------------------------------------------------------- SukiSU-Ultra

	if [ "$variant" = "sukisu-ultra" ]; then
		local dir
		dir=$(sukisu_patch_dir)

		local p

		for p in \
			"${dir}/${kver}/"*hook*.patch \
			"${dir}/hooks/syscall_hooks.patch"
		do
			[ -f "$p" ] || continue

			if (
				cd "$KERNEL_DIR"
				patch -p1 --dry-run < "$p" >/dev/null 2>&1
			); then
				(
					cd "$KERNEL_DIR"
					apply_patch "$p" 1
				) || die "SukiSU hook patch failed"

				ok "SukiSU hooks applied"
				endgroup
				return 0
			fi
		done
	fi

	# ----------------------------------------------------------- legacy fallback

	local legacy="${REPO_ROOT}/patches/legacy_ksu_hooks.sh"

	if [ -f "$legacy" ]; then
		info "falling back to bundled legacy KernelSU hook script"
		(
			cd "$KERNEL_DIR"
			bash "$legacy"
		)
	else
		warn "legacy hook script not found: ${legacy}"
	fi

	endgroup
}

# ======================================================================== KPM

kpm_patch_image() {
	local image=$1

	group "Applying KPM (patch_linux)"

	[ -f "$image" ] ||
		die "KPM input image not found: ${image}"

	local dir
	dir=$(sukisu_patch_dir)

	local tool="${dir}/kpm/patch_linux"

	[ -f "$tool" ] ||
		die "kpm/patch_linux not found in ${SUKISU_PATCH_REPO}"

	chmod +x "$tool"

	(
		cd "$(dirname "$image")"
		"$tool" "$(basename "$image")"
	) || die "patch_linux failed"

	local out="$(dirname "$image")/oImage"

	[ -f "$out" ] ||
		die "patch_linux did not produce oImage"

	mv -f "$out" "$image"

	ok "KPM applied to $(basename "$image")"
	summary "| KPM | applied |"

	endgroup
}

# ----------------------------------------------------------------------- main

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
	case "${1:-all}" in

		susfs)
			susfs_apply
			;;

		path_umount)
			path_umount_apply
			;;

		hide_stuff)
			hide_stuff_apply
			;;

		hooks)
			hooks_patch_apply
			;;

		kpm)
			[ -n "${2:-}" ] ||
				die "kpm requires the image path"

			kpm_patch_image "$2"
			;;

		all)
			# Order matters:
			#
			# 1. path_umount
			# 2. manual hooks
			# 3. SUSFS
			# 4. hide_stuff
			#
			# The first two operate on kernel files that SUSFS can modify,
			# therefore they are deliberately executed before SUSFS.

			if is_true "${ENABLE_PATH_UMOUNT:-false}"; then
				path_umount_apply
			fi

			if [ "${KSU_VARIANT:-none}" != "none" ] &&
				[ "${KSU_HOOK_MODE_RESOLVED:-${KSU_HOOK_MODE:-auto}}" = "manual" ]; then
				hooks_patch_apply
			fi

			if is_true "${ENABLE_SUSFS:-false}"; then
				susfs_apply
			fi

			if is_true "${ENABLE_HIDE_STUFF:-false}"; then
				hide_stuff_apply
			fi
			;;

		*)
			die "unknown patch step '$1'"
			;;
	esac
fi
