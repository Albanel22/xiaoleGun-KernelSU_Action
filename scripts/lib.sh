#!/usr/bin/env bash
# Shared helpers for the KernelSU Action build scripts.
# Sourced by every scripts/*.sh; never executed directly.

set -euo pipefail

# ---------------------------------------------------------------- bash version

if [ "${BASH_VERSINFO[0]:-0}" -lt 4 ]; then
	printf '[x] bash 4 or newer is required (found %s at %s).\n' \
		"${BASH_VERSION:-unknown}" "${BASH:-bash}" >&2
	printf '    On macOS: brew install bash, then run with /opt/homebrew/bin/bash\n' >&2
	exit 1
fi

# ---------------------------------------------------------------- logging

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
	_C_RED=$'\033[31m'
	_C_GRN=$'\033[32m'
	_C_YEL=$'\033[33m'
	_C_BLU=$'\033[34m'
	_C_DIM=$'\033[2m'
	_C_RST=$'\033[0m'
else
	_C_RED=''
	_C_GRN=''
	_C_YEL=''
	_C_BLU=''
	_C_DIM=''
	_C_RST=''
fi

info() {
	printf '%s[*]%s %s\n' "$_C_BLU" "$_C_RST" "$*"
}

ok() {
	printf '%s[+]%s %s\n' "$_C_GRN" "$_C_RST" "$*"
}

warn() {
	printf '%s[!]%s %s\n' "$_C_YEL" "$_C_RST" "$*" >&2
	[ -n "${GITHUB_ACTIONS:-}" ] &&
		printf '::warning::%s\n' "$*" || true
}

debug() {
	[ -n "${RUNNER_DEBUG:-}" ] &&
		printf '%s[d] %s%s\n' "$_C_DIM" "$*" "$_C_RST" >&2 || true
}

die() {
	printf '%s[x]%s %s\n' "$_C_RED" "$_C_RST" "$*" >&2
	[ -n "${GITHUB_ACTIONS:-}" ] &&
		printf '::error::%s\n' "$*" || true
	exit 1
}

group() {
	if [ -n "${GITHUB_ACTIONS:-}" ]; then
		printf '::group::%s\n' "$*"
	else
		info "$*"
	fi
}

endgroup() {
	if [ -n "${GITHUB_ACTIONS:-}" ]; then
		printf '::endgroup::\n'
	fi
}

# ------------------------------------------------- GitHub Actions plumbing

# export_env KEY VALUE
#
# Set for the current shell and persist for later GitHub Actions steps.
# The heredoc form safely preserves '=' and newlines in values.
export_env() {
	local key=$1
	local val=${2-}

	export "$key=$val"

	if [ -n "${GITHUB_ENV:-}" ] && [ -w "${GITHUB_ENV}" ]; then
		{
			printf '%s<<__GHEOF_%s__\n' "$key" "$key"
			printf '%s\n' "$val"
			printf '__GHEOF_%s__\n' "$key"
		} >>"$GITHUB_ENV"
	fi
}

summary() {
	if [ -n "${GITHUB_STEP_SUMMARY:-}" ] &&
		[ -w "${GITHUB_STEP_SUMMARY}" ]; then
		printf '%s\n' "$*" >>"$GITHUB_STEP_SUMMARY"
	fi
}

# ------------------------------------------------------------ true / false

is_true() {
	case "$(printf '%s' "${1-}" |
		tr '[:upper:]' '[:lower:]' |
		tr -d '[:space:]')" in
		true | yes | y | on | 1)
			return 0
			;;
		*)
			return 1
			;;
	esac
}

# ------------------------------------------------------------------ retry

# retry ATTEMPTS COMMAND...
retry() {
	local attempts=$1
	shift

	local n=1
	local delay=5

	until "$@"; do
		if [ "$n" -ge "$attempts" ]; then
			warn "command failed after ${attempts} attempts: $*"
			return 1
		fi

		warn "attempt ${n}/${attempts} failed, retrying in ${delay}s: $*"

		sleep "$delay"

		n=$((n + 1))
		delay=$((delay * 2))

		[ "$delay" -gt 60 ] && delay=60
	done

	return 0
}

# ------------------------------------------------------------- downloading

fetch() {
	local url=$1
	local dest=$2

	info "fetching ${url}"

	retry 4 curl \
		-fsSL \
		--connect-timeout 30 \
		--retry 3 \
		--retry-delay 3 \
		-o "$dest" \
		"$url" ||
		die "failed to download ${url}"

	[ -s "$dest" ] ||
		die "downloaded file is empty: ${url}"
}

fetch_stdout() {
	retry 4 curl \
		-fsSL \
		--connect-timeout 30 \
		"$1"
}

extract_archive() {
	local file=$1
	local dest=$2

	mkdir -p "$dest"

	case "$file" in
		*.tar.gz | *.tgz)
			tar -C "$dest" -xzf "$file"
			;;
		*.tar.xz)
			tar -C "$dest" -xJf "$file"
			;;
		*.tar.zst)
			tar -C "$dest" --zstd -xf "$file"
			;;
		*.tar.bz2)
			tar -C "$dest" -xjf "$file"
			;;
		*.tar)
			tar -C "$dest" -xf "$file"
			;;
		*.zip)
			unzip -qo "$file" -d "$dest"
			;;
		*)
			die "don't know how to extract ${file}"
			;;
	esac
}

# ------------------------------------------------------------- Git refs

# ref_exists REPO REF
#
# Strictly verify that a branch, tag, or commit exists.
#
# Important:
#   git ls-remote --heads --tags "$repo" "$ref"
# does NOT reliably resolve arbitrary commit SHAs.
#
# For a SHA we therefore perform an actual repository object check instead
# of blindly accepting any hexadecimal string.
ref_exists() {
	local repo=$1
	local ref=$2

	[ -n "$ref" ] || return 1

	# Branch.
	if git ls-remote \
		--exit-code \
		--heads \
		"$repo" \
		"refs/heads/${ref}" >/dev/null 2>&1; then
		return 0
	fi

	# Tag, including annotated tags.
	if git ls-remote \
		--exit-code \
		--tags \
		"$repo" \
		"refs/tags/${ref}" >/dev/null 2>&1; then
		return 0
	fi

	# Full/short commit SHA.
	if printf '%s' "$ref" |
		grep -qE '^[0-9a-fA-F]{7,40}$'; then

		local tmp
		tmp=$(mktemp -d)

		if git init -q --bare "$tmp/repo.git" 2>/dev/null; then
			if git -C "$tmp/repo.git" \
				fetch -q --depth=1 "$repo" "$ref" 2>/dev/null; then

				rm -rf "$tmp"
				return 0
			fi
		fi

		rm -rf "$tmp"
	fi

	return 1
}

# ------------------------------------------------------------- Kconfig I/O

# kconf_set FILE KEY VALUE
#
# KEY may be CONFIG_FOO or simply FOO.
kconf_set() {
	local file=$1
	local key=$2
	local val=$3

	case "$key" in
		CONFIG_*)
			;;
		*)
			key="CONFIG_${key}"
			;;
	esac

	[ -f "$file" ] ||
		die "defconfig not found: ${file}"

	# Remove existing assignment and "# CONFIG_X is not set".
	sed -i -E \
		"\%^[[:space:]]*(# )?${key}[[:space:]]*(=| is not set)%d" \
		"$file"

	if [ "$val" = "n" ]; then
		printf '# %s is not set\n' "$key" >>"$file"
	else
		printf '%s=%s\n' "$key" "$val" >>"$file"
	fi

	debug "kconfig: ${key}=${val}"
}

kconf_enable() {
	kconf_set "$1" "$2" y
}

kconf_disable() {
	kconf_set "$1" "$2" n
}

kconf_get() {
	local file=$1
	local key=$2

	case "$key" in
		CONFIG_*)
			;;
		*)
			key="CONFIG_${key}"
			;;
	esac

	sed -nE \
		"s%^[[:space:]]*${key}=(.*)$%\1%p" \
		"$file" |
		tail -n1
}

kconf_set_many() {
	local file=$1
	shift

	local kv

	for kv in "$@"; do
		[ -n "$kv" ] || continue

		case "$kv" in
			*=*)
				kconf_set \
					"$file" \
					"${kv%%=*}" \
					"${kv#*=}"
				;;
			*)
				die "invalid kconfig assignment '${kv}' (expected KEY=VALUE)"
				;;
		esac
	done
}

# ---------------------------------------------------------------- patching

# apply_patch FILE [STRIP]
#
# Returns:
#   0 = applied or already applied
#   1 = patch does not fit
apply_patch() {
	local patch_file=$1
	local strip=${2:-1}

	[ -f "$patch_file" ] ||
		die "patch not found: ${patch_file}"

	# First try a clean application.
	if patch \
		-p"$strip" \
		--dry-run \
		--force \
		--silent \
		<"$patch_file" >/dev/null 2>&1; then

		patch \
			-p"$strip" \
			--force \
			--no-backup-if-mismatch \
			<"$patch_file" >/dev/null

		ok "applied $(basename "$patch_file")"
		return 0
	fi

	# Check whether the patch is already present.
	if patch \
		-p"$strip" \
		-R \
		--dry-run \
		--force \
		--silent \
		<"$patch_file" >/dev/null 2>&1; then

		warn "$(basename "$patch_file") is already applied, skipping"
		return 0
	fi

	# Last resort: allow limited fuzz, but only after a complete dry-run.
	if patch \
		-p"$strip" \
		--dry-run \
		--force \
		--fuzz=3 \
		--silent \
		<"$patch_file" >/dev/null 2>&1; then

		patch \
			-p"$strip" \
			--force \
			--fuzz=3 \
			--no-backup-if-mismatch \
			<"$patch_file" >/dev/null

		warn "$(basename "$patch_file") applied with fuzz; verify the result"
		return 0
	fi

	warn "failed to apply $(basename "$patch_file")"
	return 1
}

# --------------------------------------------------------------- versions

# ver_ge A B
# True when A >= B.
ver_ge() {
	[ "$(printf '%s\n%s\n' "$2" "$1" |
		sort -V |
		head -n1)" = "$2" ]
}

# kernel_version DIR
#
# Return MAJOR.PATCHLEVEL from the kernel Makefile.
kernel_version() {
	local dir=${1:-.}
	local v
	local p

	v=$(
		sed -nE \
			's/^VERSION[[:space:]]*=[[:space:]]*([0-9]+).*/\1/p' \
			"${dir}/Makefile" |
			head -n1
	)

	p=$(
		sed -nE \
			's/^PATCHLEVEL[[:space:]]*=[[:space:]]*([0-9]+).*/\1/p' \
			"${dir}/Makefile" |
			head -n1
	)

	[ -n "$v" ] &&
		[ -n "$p" ] ||
		return 1

	printf '%s.%s' "$v" "$p"
}
