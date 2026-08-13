#!/usr/bin/env bash

# Kernel source patching: SUSFS, path_umount backport, hide_stuff, manual hooks.
#
# Everything here is idempotent and version-aware. Each step is skipped with a
# clear message when it is unnecessary (feature already present) rather than
# failing, because these trees are frequently already partially patched.

set -euo pipefail

# shellcheck source=scripts/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

KERNEL_DIR=${KERNEL_DIR:?KERNEL_DIR must point at the kernel source tree}
WORKSPACE=${WORKSPACE:-$(cd "${KERNEL_DIR}/.." && pwd)}

# Resolved from this file's location, not $PWD -- several helpers below run
# with the working directory changed into the kernel tree.
REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

# ====================================================================== SUSFS

# susfs_branch_for KVER -- map a kernel version onto a susfs4ksu branch.
#
# susfs4ksu is branched per kernel version. The GKI branches are named after
# the Android release they ship with; where a kernel version spans two Android
# releases (5.10 -> android12/android13, 5.15 -> android13/android14) we pick
# the older, which is the one the vast majority of trees are based on.
# Override with SUSFS_BRANCH when that guess is wrong.

susfs_branch_for() {
	case "$1" in
		4.9)  echo "kernel-4.9" ;;
		4.14) echo "kernel-4.14" ;;
		4.19) echo "kernel-4.19" ;;
		5.4)  echo "kernel-5.4" ;;
		5.10) echo "gki-android12-5.10" ;;
		5.15) echo "gki-android13-5.15" ;;
		6.1)  echo "gki-android14-6.1" ;;
		6.6) echo "gki-android15-6.6" ;;
		6.12) echo "gki-android16-6.12" ;;
		*)    echo "" ;;
	esac
}

susfs_apply() {
	local repo=${SUSFS_REPO:-https://gitlab.com/simonpunk/susfs4ksu.git}
	local branch=${SUSFS_BRANCH:-auto}
	local kver

	kver=$(kernel_version "$KERNEL_DIR") ||
		die "cannot read kernel version from ${KERNEL_DIR}/Makefile"

	group "Applying SUSFS"

	if [ "$branch" = "auto" ]; then
		branch=$(susfs_branch_for "$kver")

		if [ -z "$branch" ]; then
			die "no susfs4ksu branch is known for kernel ${kver}; set SUSFS_BRANCH explicitly.
   Available: $(git ls-remote --heads "$repo" | awk '{print $2}' | sed 's@refs/heads/@@' | tr '\n' ' ')"
		fi

		info "kernel ${kver} -> susfs branch '${branch}'"
	fi

	ref_exists "$repo" "$branch" ||
		die "susfs4ksu has no branch '${branch}'.
   Available: $(git ls-remote --heads "$repo" | awk '{print $2}' | sed 's@refs/heads/@@' | tr '\n' ' ')"

	local susfs_dir="${WORKSPACE}/susfs4ksu"
	rm -rf "$susfs_dir"

	retry 3 git clone -q --depth=1 -b "$branch" "$repo" "$susfs_dir" ||
		die "failed to clone ${repo} @ ${branch}"

	local kp="${susfs_dir}/kernel_patches"
	[ -d "$kp" ] || die "unexpected susfs4ksu layout: ${kp} missing"

	# 1. Drop in the SUSFS sources.
	info "copying SUSFS sources into the kernel tree"

	cp -v "${kp}/fs/"*.c "${KERNEL_DIR}/fs/" 2>/dev/null || true
	cp -v "${kp}/include/linux/"*.h "${KERNEL_DIR}/include/linux/" 2>/dev/null || true

	# 2. Patch the kernel itself.
	local kernel_patch="${kp}/50_add_susfs_in_${branch}.patch"

	[ -f "$kernel_patch" ] || {
		kernel_patch=$(find "$kp" -maxdepth 1 \
			-name '50_add_susfs_in_*.patch' | head -n1)
	}

	[ -n "$kernel_patch" ] && [ -f "$kernel_patch" ] ||
		die "no 50_add_susfs_in_*.patch found in ${kp}"

	(
		cd "$KERNEL_DIR"
		apply_patch "$kernel_patch" 1
	) || die "the SUSFS kernel patch did not apply cleanly.
   This usually means SUSFS_BRANCH does not match your kernel. Detected
   kernel ${kver}, used branch '${branch}'."

	# 3. Patch the KernelSU side only when required.
	local ksu_dir="${KERNEL_DIR}/${KSU_DIR:-KernelSU}"
	local ksu_patch="${kp}/KernelSU/10_enable_susfs_for_ksu.patch"

	if susfs_is_bundled; then
		info "${KSU_NAME:-the selected variant} already bundles SUSFS at ref '${KSU_REF_RESOLVED:-}'; skipping 10_enable_susfs_for_ksu.patch"
	elif [ ! -d "$ksu_dir" ]; then
		warn "KernelSU directory ${ksu_dir} not found; skipping the KernelSU-side SUSFS patch"
	elif [ ! -f "$ksu_patch" ]; then
		warn "branch ${branch} ships no KernelSU/10_enable_susfs_for_ksu.patch; skipping"
	else
		(
			cd "$ksu_dir"
			apply_patch "$ksu_patch" 1
		) || {
			warn "the KernelSU-side SUSFS patch did not apply."
			warn "susfs4ksu's non-GKI branches were last updated in early 2025 and still"
			warn "target the old flat KernelSU layout; modern forks have since moved to a"
			warn "modular kernel/ tree. Try a variant/ref whose layout matches, or a fork"
			warn "that bundles SUSFS itself (e.g. KSU_VARIANT=sukisu-ultra KSU_REF=builtin)."
			die "SUSFS integration failed"
		}
	fi

	# Record SUSFS version.
	local sv
	sv=$(sed -nE 's/.*SUSFS_VERSION[[:space:]]+"([^"]+)".*/\1/p' \
		"${KERNEL_DIR}/include/linux/susfs.h" 2>/dev/null | head -n1)

	export_env SUSFS_VERSION "${sv:-unknown}"
	export_env SUSFS_BRANCH_RESOLVED "$branch"

	ok "SUSFS ${sv:-?} applied from branch ${branch}"
	summary "| SUSFS | \`${sv:-unknown}\` (branch \`${branch}\`) |"

	endgroup
}

# Does the selected variant+ref already contain SUSFS?
susfs_is_bundled() {
	local bundled=${KSU_SUSFS_BUNDLED_REFS:--}
	local ref=${KSU_REF_RESOLVED:-}

	[ "$bundled" = "-" ] && return 1

	local r
	for r in $bundled; do
		[ "$r" = "$ref" ] && return 0
	done

	# Fall back to inspecting the tree, which is authoritative.
	local ksu_dir="${KERNEL_DIR}/${KSU_DIR:-KernelSU}"

	[ -d "$ksu_dir" ] &&
		grep -rqsE 'CONFIG_KSU_SUSFS|config KSU_SUSFS' \
			"${ksu_dir}/kernel/Kconfig" 2>/dev/null
}

susfs_defconfig() {
	local defconfig=$1
	local ksu_dir="${KERNEL_DIR}/${KSU_DIR:-KernelSU}"

	# Discover SUSFS symbols from the actual patched tree.
	local syms

	syms=$(
		grep -rhoE '^[[:space:]]*config[[:space:]]+KSU_SUSFS[A-Z_]*' \
			"$ksu_dir" \
			"${KERNEL_DIR}/fs/Kconfig" \
			"${KERNEL_DIR}/drivers/kernelsu" \
			2>/dev/null |
			awk '{print $2}' |
			sort -u
	)

	if [ -z "$syms" ]; then
		die "found no KSU_SUSFS Kconfig symbols to enable.
   The SUSFS sources are in the tree but nothing declares its options, so
   the feature would silently compile out and you would ship a kernel that
   looks patched but hides nothing. Check that the KernelSU-side patch
   applied, or pick a variant that bundles SUSFS."
	fi

	local s
	local enabled=0

	for s in $syms; do
		case "$s" in
			KSU_SUSFS_SUS_SU | KSU_SUSFS_SUS_OVERLAYFS)
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
	kver=$(kernel_version "$KERNEL_DIR") ||
		die "cannot read kernel version"

	if ver_ge "$kver" "5.9"; then
		info "kernel ${kver} already provides path_umount() upstream; nothing to do"
		endgroup
		return 0
	fi

	[ -f "$ns" ] || die "fs/namespace.c not found"

	if grep -qE '^int path_umount|^static int path_umount' "$ns"; then
		info "path_umount() is already present in fs/namespace.c; nothing to do"
		endgroup
		return 0
	fi

	local anchor='Now umount can handle mount points as well as block devices'

	grep -q "$anchor" "$ns" ||
		die "could not find the insertion point in fs/namespace.c; patch this kernel manually"

	local snippet
	snippet=$(mktemp)

	# can_umount is a separate helper upstream.
	if ! grep -q 'static int can_umount' "$ns"; then
		cat >>"$snippet" <<'EOF'
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

	/* we mustn't call path_put() as that would clear mnt_expiry_mark */
	dput(path->dentry);
	mntput_no_expire(mnt);
	return ret;
}

EOF

	local lineno
	lineno=$(grep -n "$anchor" "$ns" | head -n1 | cut -d: -f1)

	local start=$lineno

	while [ "$start" -gt 1 ] &&
		! sed -n "${start}p" "$ns" | grep -q '/\*'; do
		start=$((start - 1))
	done

	local tmp
	tmp=$(mktemp)

	head -n "$((start - 1))" "$ns" >"$tmp"
	cat "$snippet" >>"$tmp"
	tail -n "+${start}" "$ns" >>"$tmp"

	mv "$tmp" "$ns"
	rm -f "$snippet"

	grep -q '^int path_umount' "$ns" ||
		die "path_umount() insertion failed"

	ok "path_umount() backported into fs/namespace.c (kernel ${kver})"
	summary "| path_umount | backported (kernel ${kver}) |"

	endgroup
}

# ============================================================== extra patches

SUKISU_PATCH_REPO=${SUKISU_PATCH_REPO:-https://github.com/ShirkNeko/SukiSU_patch.git}

# Clone the shared patch/tool repo once, on demand.
sukisu_patch_dir() {
	local dir="${WORKSPACE}/SukiSU_patch"

	if [ ! -d "$dir" ]; then
		retry 3 git clone -q --depth=1 "$SUKISU_PATCH_REPO" "$dir" ||
			die "failed to clone ${SUKISU_PATCH_REPO}"
	fi

	printf '%s' "$dir"
}

# hide_stuff removes the most obvious KernelSU fingerprints from the build.
hide_stuff_apply() {
	group "Applying hide_stuff"

	local dir
	local patch

	dir=$(sukisu_patch_dir)
	patch="${dir}/69_hide_stuff.patch"

	if [ ! -f "$patch" ]; then
		warn "69_hide_stuff.patch not found in the patch repo; skipping"
		endgroup
		return 0
	fi

	(
		cd "$KERNEL_DIR"
		apply_patch "$patch" 1
	) || warn "hide_stuff did not apply cleanly; continuing"

	endgroup
}

# Manual/syscall hook patches for pre-GKI trees.
hooks_patch_apply() {
	local variant=${KSU_VARIANT:-none}
	local kver

	kver=$(kernel_version "$KERNEL_DIR") || return 0

	group "Applying manual syscall hooks (kernel ${kver})"

	# ReSukiSU publishes scope-minimised hook patches keyed by kernel version.
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
				apply_patch "$p" 1
			); then
				endgroup
				return 0
			fi
		else
			info "ReSukiSU ships no scope-minimized patch for kernel ${kver}"
		fi
	fi

	# SukiSU's patch repo carries per-version hook patches too.
	if [ "$variant" = "sukisu-ultra" ]; then
		local dir
		local p

		dir=$(sukisu_patch_dir)

		for p in \
			"${dir}/${kver}/"*hook*.patch \
			"${dir}/hooks/syscall_hooks.patch"; do

			[ -f "$p" ] || continue

			if (
				cd "$KERNEL_DIR"
				apply_patch "$p" 1
			); then
				endgroup
				return 0
			fi
		done
	fi

	# Fall back to the bundled legacy hook script.
	info "falling back to the bundled legacy hook script"

	(
		cd "$KERNEL_DIR"
		bash "${REPO_ROOT}/patches/legacy_ksu_hooks.sh"
	)

	endgroup
}

# ======================================================================== KPM

# SukiSU-Ultra's Kernel Patch Module support needs a post-link step:
# patch_linux rewrites the built Image and emits oImage.

kpm_patch_image() {
	local image=$1

	group "Applying KPM (patch_linux)"

	local dir
	local tool

	dir=$(sukisu_patch_dir)
	tool="${dir}/kpm/patch_linux"

	[ -f "$tool" ] ||
		die "kpm/patch_linux not found in ${SUKISU_PATCH_REPO}"

	chmod +x "$tool"

	(
		cd "$(dirname "$image")"
		"$tool" "$(basename "$image")"
	) || die "patch_linux failed"

	# IMPORTANT:
	# Keep declaration and assignment separate.
	# This avoids ShellCheck SC2155 and prevents masking dirname's return value.
	local out
	out="$(dirname "$image")/oImage"

	[ -f "$out" ] ||
		die "patch_linux did not produce oImage"

	mv -f "$out" "$image"

	ok "KPM applied to $(basename "$image")"
	summary "| KPM | applied |"

	endgroup
}

# --------------------------------------------------------------------- main

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
				die "kpm requires the path to the kernel Image"
			kpm_patch_image "$2"
			;;

		all)
			# Order matters:
			# path_umount and hooks key off textual anchors in files that
			# SUSFS may later rewrite, so they go first.

			if is_true "${ENABLE_PATH_UMOUNT:-false}"; then
				path_umount_apply
			fi

			# Driven by the resolved hook mode, not the raw setting.
			if [ "${KSU_VARIANT:-none}" != "none" ] &&
				[ "${KSU_HOOK_MODE_RESOLVED:-}" = "manual" ]; then
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
