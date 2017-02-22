#!/bin/bash -e

###########################################################
#
# Shippable Enterprise Installer
#
# Supported OS: Ubuntu 14.04
# Supported bash: 4.3.11
###########################################################

# Global variables ########################################
###########################################################
readonly IFS=$'\n\t'
readonly ROOT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
readonly VERSIONS_DIR="$ROOT_DIR/versions"
readonly MIGRATIONS_DIR="$ROOT_DIR/migrations"
readonly POST_INSTALL_MIGRATIONS_DIR="$MIGRATIONS_DIR/post_install"
readonly SCRIPTS_DIR="$ROOT_DIR/scripts"
readonly USR_DIR="$ROOT_DIR/usr"
readonly LOGS_DIR="$USR_DIR/logs"
readonly TIMESTAMP="$(date +%Y_%m_%d_%H:%M:%S)"
readonly LOG_FILE="$LOGS_DIR/${TIMESTAMP}_logs.txt"
readonly MAX_DEFAULT_LOG_COUNT=6
readonly REMOTE_SCRIPTS_DIR="$ROOT_DIR/scripts/remote"
readonly LOCAL_SCRIPTS_DIR="$ROOT_DIR/scripts/local"
readonly STATE_FILE="$USR_DIR/state.json"
readonly STATE_FILE_BACKUP="$USR_DIR/state.json.backup"
readonly SSH_USER="root"
readonly SSH_PRIVATE_KEY=$USR_DIR/machinekey
readonly SSH_PUBLIC_KEY=$USR_DIR/machinekey.pub
readonly LOCAL_BRIDGE_IP=172.17.42.1
readonly API_TIMEOUT=600
export LC_ALL=C
export RELEASE_VERSION=""
export DEPLOY_TAG=""
export UPDATED_APT_PACKAGES=false

# Installation default values #############################
###########################################################
export INSTALL_MODE="local"
export SHIPPABLE_INSTALL_TYPE="production"
export SHIPPABLE_VERSION="master"
export IS_UPGRADE=false
###########################################################

source "$SCRIPTS_DIR/logger.sh"
source "$SCRIPTS_DIR/_helpers.sh"
source "$SCRIPTS_DIR/_parseArgs.sh"
source "$SCRIPTS_DIR/_execScriptRemote.sh"
source "$SCRIPTS_DIR/_copyScriptRemote.sh"
source "$SCRIPTS_DIR/_copyScriptLocal.sh"
source "$SCRIPTS_DIR/_manageState.sh"
source "$SCRIPTS_DIR/_manageState.sh"

use_latest_release() {
  __process_msg "Using latest release"

  local release_major_versions="[]"
  local release_minor_versions=""
  local release_patch_versions=""

  for filepath in $VERSIONS_DIR/*; do
    local filename=$(basename $filepath)
    local file_major_version=""
    if [[ $filename =~ ^v([0-9]).([0-9])([0-9])*.([0-9])([0-9])*.json$ ]]; then
      local file_major_version="${BASH_REMATCH[1]}"
      file_major_version=$(python -c "print int($file_major_version)")
      release_major_versions="$file_major_version,"
    fi
  done

  release_major_versions="["${release_major_versions::-1}"]"
  local release_major_versions_count=$(echo $release_major_versions | jq '. | length')
  local release_file_major_version=0
  for i in $(seq 1 $release_major_versions_count); do
    local major_version=$(echo $release_major_versions | jq -r '.['"$i-1"']')
    if [ $major_version -gt $release_file_major_version ]; then
      release_file_major_version=$major_version
    fi
  done

  for filepath in $VERSIONS_DIR/*; do
    local filename=$(basename $filepath)
    local file_minor_version=""
    if [[ $filename =~ ^v($release_file_major_version).([0-9])([0-9])*.([0-9])([0-9])*.json$ ]]; then
      local file_minor_version="${BASH_REMATCH[2]}${BASH_REMATCH[3]}"
      file_minor_version=$(python -c "print int($file_minor_version)")
      release_minor_versions="$file_minor_version,"
    fi
  done

  release_minor_versions="["${release_minor_versions::-1}"]"
  release_minor_versions_count=$(echo $release_minor_versions | jq '. | length')
  local release_file_minor_version=0
  for i in $(seq 1 $release_minor_versions_count); do
    local minor_version=$(echo $release_minor_versions | jq -r '.['"$i-1"']')
    if [ $minor_version -gt $release_file_minor_version ]; then
      release_file_minor_version=$minor_version
    fi
  done

  for filepath in $VERSIONS_DIR/*; do
    local filename=$(basename $filepath)
    local file_patch_version=""
    if [[ $filename =~ ^v($release_file_major_version).($release_file_minor_version).([0-9])([0-9])*.json$ ]]; then
      local file_patch_version="${BASH_REMATCH[3]}${BASH_REMATCH[4]}"
      file_patch_version=$(python -c "print int($file_patch_version)")
      release_patch_versions="$file_patch_version,"
    fi
  done

  release_patch_versions="["${release_patch_versions::-1}"]"
  release_patch_versions_count=$(echo $release_patch_versions | jq '. | length')
  local release_file_patch_version=0
  for i in $(seq 1 $release_patch_versions_count); do
    local patch_version=$(echo $release_patch_versions | jq -r '.['"$i-1"']')
    if [ $patch_version -gt $release_file_patch_version ]; then
      release_file_patch_version=$patch_version
    fi
  done

  local latest_release="v"$release_file_major_version"."$release_file_minor_version"."$release_file_patch_version
  __process_msg "Latest release version: $latest_release"

  export RELEASE_VERSION=$latest_release
}

install() {
  __process_msg "Running installer steps"

  if [ -z "$DEPLOY_TAG" ]; then
    export DEPLOY_TAG=latest
  fi

  source "$SCRIPTS_DIR/getConfigs.sh"
  local release_version=$(cat $STATE_FILE | jq -r '.release')
  readonly SCRIPT_DIR_REMOTE="/tmp/shippable/$release_version"
  export RELEASE_VERSION=$release_version

  source "$SCRIPTS_DIR/bootstrapMachines.sh"
  source "$SCRIPTS_DIR/installCore.sh"
  source "$SCRIPTS_DIR/bootstrapApp.sh"
  source "$SCRIPTS_DIR/provisionServices.sh"
  source "$SCRIPTS_DIR/cleanup.sh"

  __process_msg "Installation successfully completed!"
}

install_release() {
  # parse release
  local deploy_tag="$1"
  local release_file_path="$VERSIONS_DIR/$deploy_tag".json
  if [ -f $release_file_path ]; then
    __process_msg "Release file found: $release_file_path"
    local install_mode=$(cat $STATE_FILE \
      | jq -r '.installMode')
    export INSTALL_MODE="$install_mode"

    __process_msg "Running installer for release $deploy_tag"

    export RELEASE_VERSION=$deploy_tag
    export DEPLOY_TAG=$deploy_tag
    install
  else
    __process_msg "No release file found at : $release_file_path, exiting"
    exit 1
  fi
}

__set_is_upgrade() {
  if [ -f $STATE_FILE ]; then
    local update=$(cat $STATE_FILE | jq ".isUpgrade=$1")
    _update_state "$update"
  fi
}

main_new() {
  __check_logsdir
	__parse_args "$@"
	__validate_args
}

main() {
  __check_logsdir
  if [[ $# -gt 0 ]]; then
    key="$1"

    case $key in
      -s|--status) __show_status
        shift ;;
      -v|--version) __show_version
        shift ;;
      -r|--release)
        {
          shift
          if [[ ! $# -eq 1 ]]; then
            __process_msg "Mention the release version to be installed."
          else
            __check_valid_state_json
            __check_dependencies
            __set_is_upgrade true
            release_version=$(cat $STATE_FILE | jq -r '.release')
            export RELEASE_VERSION=$latest_release
            install_release $1
          fi
        } 2>&1 | tee $LOG_FILE ; ( exit ${PIPESTATUS[0]} )
        ;;
      -i|--install)
        {
          shift
          __process_marker "Booting shippable installer"
          __check_valid_state_json
          __check_dependencies
          __set_is_upgrade false
          use_latest_release
          if [[ $# -eq 1 ]]; then
            install_mode=$1
          fi
          if [ "$install_mode" == "production" ] || [ "$install_mode" == "local" ]; then
            export INSTALL_MODE="$install_mode"
            install
          else
            __process_msg "Running installer in default 'local' mode"
            install
          fi
        } 2>&1 | tee $LOG_FILE ; ( exit ${PIPESTATUS[0]} )
        ;;
      -h|--help) __print_help
        shift ;;
      *)
        __print_help
        shift ;;
    esac
    __cleanup_logfiles
  else
    __print_help
  fi
}

main_new "$@"
