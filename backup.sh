#!/usr/bin/env bash

set -euo pipefail
IFS=$'\n\t'
shopt -s globstar

# shellcheck disable=SC2155
declare -r self="$(basename "$0")"
declare -r EXIT_CODE_INVALID_ARGUMENT=3
declare -r EXIT_CODE_INVALID_STATE=2
declare -r PRINT_USAGE=true
declare -A script_config=(
	[target]=""
	[ident_file]=""
	[verbose]=null
	[dry_run]=null
	[log_color]=null
	[log_to_file]=false
	[log_file_root]="/var/logs/rsync-backup"
	[log_file_date_format]="+%Y-%m-%d"
	[log_file_date]=""
	[log_file_path]=""
	[config_root]=""
)
declare -A config
declare -a rsync_arguments
declare -a rsync_dry_run=()
declare -a rsync_verbose=()
declare -a rsync_log_file=()
declare rsync_remote_path

function reset_colors() {
	declare -g C_RESET=''
	declare -g C_LOG_DATE=''
	declare -g C_HIGHLIGHT=''
	declare -g C_INFO=''
	declare -g C_VERBOSE=''
	declare -g C_WARNING=''
	declare -g C_ERROR=''
}

function check_colors() {
	reset_colors
	# only enable colors when supported
	if [ -x /usr/bin/tput ] && tput setaf 1 >&/dev/null; then
		C_RESET="\033[0m"
		C_LOG_DATE="\033[0;36m"
		C_HIGHLIGHT="\033[1;34m"
		C_INFO="\033[0;32m"
		C_VERBOSE="\033[0;36m"
		C_WARNING="\033[1;33m"
		C_ERROR="\033[0;31m"
	fi
}

highlight() {
	if [[ -z "$C_HIGHLIGHT" ]]; then
		echo "\`$*\`"
	else
		echo "${C_HIGHLIGHT}$*${C_RESET}"
	fi
}

function message() {
	local message
	message="[${C_LOG_DATE}$(date '+%Y/%m/%d %H:%M:%S')${C_RESET}] $*"
	if [[ "${script_config[log_to_file]}" == "true" ]]; then
		echo "${message}" >> "${script_config[log_file_path]}"
	else
		echo -e "${message}"
	fi
}

function info_message() {
	message "${C_INFO}   [INFO]${C_RESET} $*"
}

function verbose_message() {
	if [[ "${script_config[verbose]}" == "true" ]]; then
		message "${C_VERBOSE}[VERBOSE]${C_RESET} $*"
	fi
}

function warning() {
	message "${C_WARNING}[WARNING]${C_RESET} $*"
}

function error() {
	# use error code provided if set, else last commands error code
	local err=${2-$?}

	>&2 message "${C_ERROR}  [ERROR]${C_RESET} ${1}"

	if [[ -n "${3-}" && "${3-}" != "false" ]]; then
		>&2 usage
	fi

	if [[ -n ${err} ]]; then
		exit "$err"
	fi
}

function usage() {
	echo -e
	echo -e "rsync backup"
	echo -e
	echo -e "Usage: ${self} [options] <path-to-config-root>"
	echo -e
	echo -e "Options:"
	echo -e "  $(highlight "--verbose, -v")     Show more verbose output of actions performed."
	echo -e
	echo -e "  $(highlight "--no-color")        Disable colored output."
	echo -e
	echo -e "  $(highlight "--dry-run")         Run rsync in dry run mode. Providing this options also assumes $(highlight "--verbose")."
	echo -e
	echo -e "  $(highlight "--help")            Show this usage message and exit."
	echo -e
}

function join_by {
	local d="${1-}"
	local f="${2-}"
	if shift 2; then
		printf %s "$f" "${@/#/$d}"
	fi
}

function validate_required() {
	local validation_message="$1"
	shift
	local value="$1"
	shift

	if [[ -z "$value" ]]; then
		error "$validation_message" ${EXIT_CODE_INVALID_ARGUMENT}
	fi
}

function validate_integer() {
	local validation_message="$1"
	shift
	local value="$1"
	shift

	if ! [[ "$value" =~ ^[0-9]+$ ]] ; then
		error "$validation_message" ${EXIT_CODE_INVALID_ARGUMENT}
	fi
}

function validate_value_in() {
	local validation_message="$1"
	shift
	local value="$1"
	shift
	declare -a values=( )

	while (($#)); do
		values+=( "$1" )
		if [[ "$value" == "$1" ]]; then
			return 0
		fi
		shift
	done

	error "$validation_message - Value: ${value} - Allowed values: $(join_by ", " "${values[@]}")" ${EXIT_CODE_INVALID_ARGUMENT}
}

function validate_requirements() {
	command -v rsync &> /dev/null \
		|| error "rsync command wasn't found; please install and ensure it's on the PATH" ${EXIT_CODE_INVALID_STATE}

	command -v ssh &> /dev/null \
		|| error "ssh command wasn't found; please install and ensure it's on the PATH" ${EXIT_CODE_INVALID_STATE}
}

function read_script_config() {
	local log_file_date
	local name
	local config_path="$1"

	if [[ ! -f "$config_path" ]]; then
		error "Invalid config path: $(highlight "$config_path")" ${EXIT_CODE_INVALID_ARGUMENT}
	fi

	# read config variables
	while IFS= read -r line || [[ -n "$line" ]]; do
		# line must have a `=`
		if [[ "$line" == \#* ]]; then
			verbose_message "Skipping: $line"
			continue
		elif ! echo "$line" | grep -F '=' &> /dev/null; then
			warning "Invalid line in $(highlight "${id}"): $line"
			continue
		fi
		name="$(echo "$line" | cut -d '=' -f 1)"
		if [[\
		 	( "$name" == "verbose" || "$name" == "dry_run" || "$name" == "log_color" || "$name" == "config_root")\
		 	&& "${script_config["$name"]}" != "null"\
		]]; then
			continue
		fi
		script_config["$name"]="$(echo "$line" | cut -d '=' -f 2-)"
	done < "$config_path"

	if [[ "${script_config[log_color]}" == "null" ]]; then
		if [[ "${script_config[log_to_file]}" == "true" ]]; then
			script_config[log_color]="false"
		else
			script_config[log_color]="true"
		fi
	fi

	if [[ "${script_config[dry_run]}" == "null" ]]; then
		script_config[dry_run]="false"
	fi

	if [[ "${script_config[verbose]}" == "null" ]]; then
		script_config[verbose]="false"
	fi

	validate_required "$(highlight "$config_path") missing $(highlight target)" "${script_config[target]}"
	validate_required "$(highlight "$config_path") missing $(highlight ident_file)" "${script_config[ident_file]}"
	validate_required "$(highlight "$config_path") missing $(highlight log_file_root)" "${script_config[log_file_root]}"
	validate_required "$(highlight "$config_path") missing $(highlight log_file_date_format)" "${script_config[log_file_date_format]}"
	validate_value_in "$(highlight "$config_path") invalid value for $(highlight verbose)" "${script_config[verbose]}" "true" "false"
	validate_value_in "$(highlight "$config_path") invalid value for $(highlight dry_run)" "${script_config[dry_run]}" "true" "false"
	validate_value_in "$(highlight "$config_path") invalid value for $(highlight log_to_file)" "${script_config[log_to_file]}" "true" "false"
	validate_value_in "$(highlight "$config_path") invalid value for $(highlight log_color)" "${script_config[log_color]}" "true" "false"

	script_config[log_file_date]="$(date "${script_config[log_file_date_format]}")"
	script_config[log_file_path]="${script_config[log_file_path]}/backup-${script_config[log_file_date]}.log"
}

function read_id_config() {
	local config_path="$1/config"
	local id
	local name
	id="$(basename "$config_path")"

	config=(
		[id]="$id"
		[skip]="false"
		[remote_user]="root"
		[remote_host]=""
		[remote_port]=""
		[ident_file]=""
	)

	if [[ ! -f "$config_path" ]]; then
		error "No config found for $id" ${EXIT_CODE_INVALID_STATE}
	fi

	# read config variables
	while IFS= read -r line || [[ -n "$line" ]]; do
		# line must have a `=`
		if [[ "$line" == \#* ]]; then
			verbose_message "Skipping: $line"
			continue
		elif ! echo "$line" | grep -F '=' &> /dev/null; then
			warning "Invalid line in ${id}: $line"
			continue
		fi
		name="$(echo "$line" | cut -d '=' -f 1)"
		config["$name"]="$(echo "$line" | cut -d '=' -f 2-)"
	done < "$config_path"

	validate_required "$(highlight "$config_path") has invalid $(highlight id)" "${config[id]}"
	validate_required "$(highlight "$config_path") has invalid $(highlight remote_user)" "${config[remote_user]}"
	validate_required "$(highlight "$config_path") missing $(highlight remote_host)" "${config[remote_host]}"
	if [[ -n "${config[remote_port]}" ]]; then
		validate_integer "$(highlight "$config_path") has $(highlight remote_port) with a non-integer value " "${config[remote_port]}"
	fi
	validate_value_in "$(highlight "$config_path") invalid value for $(highlight skip)" "${config[skip]}" "true" "false"
}

function read_files_config() {
	local name
	local value
	local id="$1"
	local config_path="$2"
	rsync_arguments=()
	rsync_remote_path=""

	if [[ ! -f "$config_path" ]]; then
		error "No paths found for $(highlight "$id")" ${EXIT_CODE_INVALID_STATE}
	fi

	# shellcheck disable=SC2094
	while IFS= read -r line || [[ -n "$line" ]]; do
		# line must have a `=`
		if [[ "$line" == \#* ]]; then
			verbose_message "Skipping: $line"
			continue
		elif ! echo "$line" | grep -F '=' &> /dev/null; then
			warning "Invalid line in $(highlight "$id"): $line"
			continue
		fi

		name="$(echo "$line" | cut -d '=' -f 1)"
		value="$(echo "$line" | cut -d '=' -f 2-)"

		case "$name" in
			"path")
				if [[ -n "$rsync_remote_path" ]]; then
					warning "$(highlight "$config_path") has duplicate $(highlight path)s"
				fi
				rsync_remote_path="$value"
				;;
			"include")
				validate_required "$(highlight "$config_path") has invalid $(highlight include)" "$value"
				rsync_arguments+=( --include="$value" )
				;;
			"exclude")
				validate_required "$(highlight "$config_path") has invalid $(highlight exclude)" "$value"
				rsync_arguments+=( --exclude="$value" )
				;;
			*)
				warning "Invalid line in $(highlight "$id"): $line"
				;;
		esac
	done < "$config_path"

	validate_required "$(highlight "$config_path") is missing $(highlight path)" "$rsync_remote_path"
}

function parse_args() {
	while (($#)); do
		case "$1" in
			-v|--verbose)
				script_config[verbose]=true
				;;
			--no-color)
				script_config[log_color]=false
				;;
			--dry-run)
				script_config[verbose]=true
				script_config[dry_run]=true
				;;
			-h|--help)
				usage
				exit 0
				;;
			--*)
				error "Unexpected argument: $(highlight "$1")" ${EXIT_CODE_INVALID_ARGUMENT} ${PRINT_USAGE}
				;;
			*)
				if [[ -n "${script_config[config_root]}" ]]; then
					error "Multiple config paths provided" ${EXIT_CODE_INVALID_ARGUMENT}
				fi
				script_config[config_root]="$1"
				;;
		esac
		shift
	done

	validate_required "No config path provided" "${script_config[config_root]}"
}

function sync() {
	declare -a ssh_port=( )
	declare -a ssh_ident=( )
	declare -a ssh_verbose=( )

	if [[ -n "${config[remote_port]}" ]]; then
		ssh_port=( -p "${config[remote_port]}" )
	fi

	if [[ -n "${config[ident_file]}" ]]; then
		ssh_ident=( -i "${config[ident_file]}" )
	elif [[ -n "${script_config[ident_file]}" ]]; then
		ssh_ident=( -i "${script_config[ident_file]}" )
	fi

	if [[ "${script_config[verbose]}" == "true" ]]; then
		ssh_verbose=( -vvv )
	fi

	# Create the connection string.
	local ssh_connect="${config[remote_user]}@${config[remote_host]}"

	verbose_message "Checking SSH connection"
	ssh \
		-q \
		-o 'BatchMode=yes' \
		-o 'ConnectTimeout 10' \
		"${ssh_verbose[@]}" \
		"${ssh_ident[@]}" \
		"${ssh_port[@]}" \
		"${ssh_connect}" \
		exit \
	> /dev/null || error "SSH connection to $(highlight "$ssh_connect")' failed."

	local rsync_ssh_command=( ssh "${ssh_ident[@]}" "${ssh_port[@]}" )

	local target="${script_config[target]}/${config[id]}"
	mkdir -p "$target" || error "Error creating ${script_config[log_file_root]}"

	# shellcheck disable=SC2124
	local rsh_args="${rsync_ssh_command[@]}"

	rsync \
		"${rsync_dry_run[@]}" \
		"${rsync_verbose[@]}" \
		"${rsync_log_file[@]}" \
		--copy-links \
		--copy-dirlinks \
		--progress \
		--archive \
		--compress \
		--human-readable \
		--delete \
		--delete-excluded \
		--rsh="$rsh_args"\
		"${rsync_arguments[@]}" \
		"$ssh_connect:$rsync_remote_path" \
		"$target"
}

function main() {
	check_colors
	parse_args "${@}"

	validate_requirements

	local script_config_path="${script_config[config_root]}/config"

	read_script_config "$script_config_path"

	if [[ "${script_config[log_to_file]}" == "true" ]]; then
		mkdir -p "${script_config[log_file_root]}" || error "Error creating ${script_config[log_file_root]}"
		touch "${script_config[log_file_path]}" || error "Error creating ${script_config[log_file_path]}"
	fi

	if [[ "${script_config[verbose]}" == "true" ]]; then
		rsync_dry_run=(--verbose )
	fi

	if [[ ! -d "${script_config[target]}" ]]; then
		error "The target directory $(highlight "${script_config[target]}") does not exist or is not a directory" ${EXIT_CODE_INVALID_STATE}
	fi

	if [[ "${script_config[dry_run]}" == "true" ]]; then
		rsync_dry_run=(--dry-run --itemize-changes)
	fi


	for config_path in "${script_config[config_root]}"/*; do
		if [[ "$config_path" == "$script_config_path" ]]; then
			continue
		fi

		read_id_config "$config_path"

		if [[ "${config[skip]}" == "true" ]]; then
			continue
		fi

		for pattern_path in "$config_path"/files.d/*; do
			read_files_config "${config[id]}" "$pattern_path"
			sync
		done
	done
}

main "${@}"