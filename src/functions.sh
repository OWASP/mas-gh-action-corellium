#!/bin/bash
#
# Define reusable functions for CI

check_env_vars()
{
  if [ -z "${CORELLIUM_API_ENDPOINT}" ]; then
    log_error 'CORELLIUM_API_ENDPOINT not set.'
    exit 1
  elif [ -z "${CORELLIUM_API_TOKEN}" ]; then
    log_error 'CORELLIUM_API_TOKEN not set.'
    exit 1
  fi
}

log_stdout()
{
  MAKE_CONSOLE_BLUE="$(tput setaf 4)"
  MAKE_CONSOLE_NORMAL="$(tput sgr0)"
  local FRIENDLY_DATE
  FRIENDLY_DATE="$(date +'%Y-%m-%dT%H:%M:%S')"
  if [ "$#" -gt 0 ]; then
    for arg in "$@"; do
      printf '%s[+] %s INFO: %s\n%s' \
        "${MAKE_CONSOLE_BLUE}" \
        "${FRIENDLY_DATE}" \
        "${arg}" \
        "${MAKE_CONSOLE_NORMAL}"
    done
  else
    log_error 'No argument supplied to log_stdout.'
    exit 1
  fi
}

log_error()
{
  MAKE_CONSOLE_RED="$(tput setaf 1)"
  MAKE_CONSOLE_NORMAL="$(tput sgr0)"
  local FRIENDLY_DATE
  FRIENDLY_DATE="$(date +'%Y-%m-%dT%H:%M:%S')"
  if [ "$#" -gt 0 ]; then
    for arg in "$@"; do
      printf '%s[!] %s  ERR: %s\n%s' \
        "${MAKE_CONSOLE_RED}" \
        "${FRIENDLY_DATE}" \
        "${arg}" \
        "${MAKE_CONSOLE_NORMAL}" \
        >&2
    done
  else
    printf '%s[!] %s  ERR: No argument supplied to log_error.\n%s' \
      "${MAKE_CONSOLE_RED}" \
      "${FRIENDLY_DATE}" \
      "${MAKE_CONSOLE_NORMAL}" \
      >&2
  fi
}

log_warn()
{
  MAKE_CONSOLE_YELLOW="$(tput setaf 3)"
  MAKE_CONSOLE_NORMAL="$(tput sgr0)"
  local FRIENDLY_DATE
  FRIENDLY_DATE="$(date +'%Y-%m-%dT%H:%M:%S')"
  if [ "$#" -gt 0 ]; then
    for arg in "$@"; do
      printf '%s[!] %s  WARN: %s\n%s' \
        "${MAKE_CONSOLE_YELLOW}" \
        "${FRIENDLY_DATE}" \
        "${arg}" \
        "${MAKE_CONSOLE_NORMAL}" \
        >&2
    done
  else
    log_error 'No argument supplied to log_warn'
    exit 1
  fi
}

does_instance_exist()
{
  local INSTANCE_ID="$1"
  if corellium instance get --instance "${INSTANCE_ID}" 2> /dev/null |
    jq -e --arg id "${INSTANCE_ID}" 'select(.id == $id)' > /dev/null; then
    return 0
  else
    log_warn "Instance ${INSTANCE_ID} does not exist."
    return 1
  fi
}

get_available_cores()
{
  local PROJECT_ID="$1"
  local GET_PROJECTS_RESPONSE_JSON AVAILABLE_PROJECT_CORES
  GET_PROJECTS_RESPONSE_JSON="$(corellium project list)" || {
    log_error "Failed to get projects list."
    return
  }

  echo "${GET_PROJECTS_RESPONSE_JSON}" |
    jq -e --arg id "${PROJECT_ID}" 'any(.[]; .id == $id)' > /dev/null || {
    log_error "Project ${PROJECT_ID} does not exist."
    exit 1
  }

  AVAILABLE_PROJECT_CORES="$(echo "${GET_PROJECTS_RESPONSE_JSON}" |
    jq --arg project_id "${PROJECT_ID}" \
      '.[] | select(.id == $project_id) | .quotas.cores - .quotasUsed.cores')"
  echo "${AVAILABLE_PROJECT_CORES}"
}

wait_until_available_cores()
{
  local PROJECT_ID="$1"
  local REQUIRED_CORES="${2:-6}"
  local WAIT_CORES_SLEEP_TIME_SECONDS='15'
  [ -z "${PROJECT_ID}" ] && {
    log_error 'Project ID must be set.'
    exit 1
  }
  log_stdout "Waiting until ${REQUIRED_CORES} CPU cores are available."
  local AVAILABLE_CORES
  AVAILABLE_CORES="$(get_available_cores "${PROJECT_ID}")"
  while [ "${AVAILABLE_CORES:-0}" -lt "${REQUIRED_CORES}" ]; do
    log_warn "Only ${AVAILABLE_CORES} CPU cores are available."
    sleep "${WAIT_CORES_SLEEP_TIME_SECONDS}"
    AVAILABLE_CORES="$(get_available_cores "${PROJECT_ID}")"
  done
  log_stdout "${AVAILABLE_CORES} CPU cores are available."
}

create_instance()
{
  local HARDWARE_FLAVOR="$1"
  local FIRMWARE_VERSION="$2"
  local FIRMWARE_BUILD="$3"
  local PROJECT_ID="$4"
  local NEW_INSTANCE_NAME
  NEW_INSTANCE_NAME="Frida automation $(date '+%Y-%m-%d_%H-%M-%S')"

  if [ "${HARDWARE_FLAVOR}" = 'ranchu' ]; then
    CREATE_INSTANCE_REQUEST_DATA=$(
      cat << EOF
{
  "project": "${PROJECT_ID}",
  "name": "${NEW_INSTANCE_NAME}",
  "flavor": "${HARDWARE_FLAVOR}",
  "os": "${FIRMWARE_VERSION}",
  "osbuild": "${FIRMWARE_BUILD}",
  "bootOptions": {"cores": 4,"ram": 4096}
}
EOF
    )
  else
    CREATE_INSTANCE_REQUEST_DATA=$(
      cat << EOF
{
  "project": "${PROJECT_ID}",
  "name": "${NEW_INSTANCE_NAME}",
  "flavor": "${HARDWARE_FLAVOR}",
  "os": "${FIRMWARE_VERSION}",
  "osbuild": "${FIRMWARE_BUILD}"
}
EOF
    )
  fi

  CREATE_INSTANCE_RESPONSE_JSON="$(curl --silent -X POST "${CORELLIUM_API_ENDPOINT}/api/v1/instances" \
    -H "Accept: application/json" \
    -H "Authorization: Bearer ${CORELLIUM_API_TOKEN}" \
    -H "Content-Type: application/json" \
    -d "${CREATE_INSTANCE_REQUEST_DATA}")" || {
    log_error "Failed to create new instance in project ${PROJECT_ID}."
    echo "${CREATE_INSTANCE_REQUEST_DATA}" >&2
    exit 1
  }

  CREATED_INSTANCE_ID="$(echo "${CREATE_INSTANCE_RESPONSE_JSON}" | jq -r .id)" || {
    log_error 'Response does not contain a new instance ID.'
    log_error "$(echo "${CREATE_INSTANCE_RESPONSE_JSON}" | jq -r .error)"
    exit 1
  }

  [ "${CREATED_INSTANCE_ID}" = 'null' ] && {
    log_error 'Response contains a null instance ID.'
    log_error "$(echo "${CREATE_INSTANCE_RESPONSE_JSON}" | jq -r .error)"
    exit 1
  }

  echo "${CREATED_INSTANCE_ID}"
}

delete_instance()
{
  local INSTANCE_ID="$1"
  log_stdout "Deleting instance ${INSTANCE_ID}."
  corellium instance delete "${INSTANCE_ID}" > /dev/null || {
    log_error "Failed to delete instance ${INSTANCE_ID}."
    exit 1
  }
  log_stdout "Deleted instance ${INSTANCE_ID}."
}

start_instance()
{
  local INSTANCE_ID="$1"
  local INSTANCE_STATUS_ON='on'
  local INSTANCE_STATUS_CREATING='creating'
  does_instance_exist "${INSTANCE_ID}" || exit 1
  case "$(get_instance_status "${INSTANCE_ID}")" in
    "${INSTANCE_STATUS_ON}")
      log_stdout "Instance ${INSTANCE_ID} is already ${INSTANCE_STATUS_ON}."
      ;;
    "${INSTANCE_STATUS_CREATING}")
      log_stdout "Instance ${INSTANCE_ID} is ${INSTANCE_STATUS_CREATING}. Waiting for ${INSTANCE_STATUS_ON} state."
      wait_for_instance_status "${INSTANCE_ID}" "${INSTANCE_STATUS_ON}"
      log_stdout "Instance ${INSTANCE_ID} is ${INSTANCE_STATUS_ON}."
      ;;
    '')
      log_error "Failed to get status for instance ${INSTANCE_ID}."
      exit 1
      ;;
    *)
      log_stdout "Starting instance ${INSTANCE_ID}."
      corellium instance start "${INSTANCE_ID}" --wait > /dev/null
      log_stdout "Instance ${INSTANCE_ID} is ${INSTANCE_STATUS_ON}."
      ;;
  esac
}

stop_instance()
{
  local INSTANCE_ID="$1"
  local INSTANCE_STATUS_OFF='off'
  local INSTANCE_STATUS_ON='on'
  local INSTANCE_STATUS_CREATING='creating'
  does_instance_exist "${INSTANCE_ID}" || exit 1
  case "$(get_instance_status "${INSTANCE_ID}")" in
    "${INSTANCE_STATUS_OFF}")
      log_stdout "Instance ${INSTANCE_ID} is already ${INSTANCE_STATUS_OFF}."
      ;;
    "${INSTANCE_STATUS_CREATING}")
      log_stdout "Instance ${INSTANCE_ID} is ${INSTANCE_STATUS_CREATING}. Waiting for ${INSTANCE_STATUS_ON} state."
      wait_for_instance_status "${INSTANCE_ID}" "${INSTANCE_STATUS_ON}"
      log_stdout "Instance ${INSTANCE_ID} is ${INSTANCE_STATUS_ON}."
      log_stdout "Stopping instance ${INSTANCE_ID}."
      corellium instance stop "${INSTANCE_ID}" --wait > /dev/null
      log_stdout "Instance ${INSTANCE_ID} is ${INSTANCE_STATUS_OFF}."
      ;;
    '')
      log_error "Failed to get status for instance ${INSTANCE_ID}."
      exit 1
      ;;
    *)
      log_stdout "Stopping instance ${INSTANCE_ID}."
      corellium instance stop "${INSTANCE_ID}" --wait > /dev/null
      log_stdout "Instance ${INSTANCE_ID} is ${INSTANCE_STATUS_OFF}."
      ;;
  esac
}

soft_stop_instance()
{
  local INSTANCE_ID="$1"
  local INSTANCE_STATUS_OFF='off'
  does_instance_exist "${INSTANCE_ID}" || exit 1
  case "$(get_instance_status "${INSTANCE_ID}")" in
    "${INSTANCE_STATUS_OFF}")
      log_stdout "Instance ${INSTANCE_ID} is already ${INSTANCE_STATUS_OFF}."
      ;;
    '')
      log_error "Failed to get status for instance ${INSTANCE_ID}."
      exit 1
      ;;
    *)
      log_stdout "Stopping instance ${INSTANCE_ID}."
      check_env_vars
      curl --silent -X POST "${CORELLIUM_API_ENDPOINT}/api/v1/instances/${INSTANCE_ID}/stop" \
        -H "Accept: application/json" \
        -H "Authorization: Bearer ${CORELLIUM_API_TOKEN}" \
        -H "Content-Type: application/json" \
        -d '{"soft":true}'
      log_stdout "Soft stopped instance ${INSTANCE_ID}. Waiting for ${INSTANCE_STATUS_OFF} state."
      wait_for_instance_status "${INSTANCE_ID}" "${INSTANCE_STATUS_OFF}"
      log_stdout "Instance ${INSTANCE_ID} is ${INSTANCE_STATUS_OFF}."
      ;;
  esac
}

get_instance_status()
{
  local INSTANCE_ID="$1"
  local GET_INSTANCE_RESPONSE_JSON INSTANCE_STATE
  GET_INSTANCE_RESPONSE_JSON="$(corellium instance get --instance "${INSTANCE_ID}")" || {
    log_error "Failed to get details for instance ${INSTANCE_ID}."
    return
  }
  INSTANCE_STATE="$(echo "${GET_INSTANCE_RESPONSE_JSON}" | jq -r '.state')" || {
    log_error "Failed to parse get details JSON response for instance ${INSTANCE_ID}."
    exit 1
  }
  echo "${INSTANCE_STATE}"
}

get_instance_services_ip()
{
  local INSTANCE_ID="$1"
  local GET_INSTANCE_RESPONSE_JSON INSTANCE_SERVICES_IP
  GET_INSTANCE_RESPONSE_JSON="$(corellium instance get --instance "${INSTANCE_ID}")" || {
    log_error "Failed to get details for instance ${INSTANCE_ID}."
    exit 1
  }
  INSTANCE_SERVICES_IP="$(echo "${GET_INSTANCE_RESPONSE_JSON}" | jq -r '.serviceIp')" || {
    log_error "Failed to parse get details JSON response for instance ${INSTANCE_ID}."
    exit 1
  }
  echo "${INSTANCE_SERVICES_IP}"
}

get_instance_udid()
{
  local INSTANCE_ID="$1"
  local GET_INSTANCE_RESPONSE_JSON INSTANCE_UDID
  GET_INSTANCE_RESPONSE_JSON="$(corellium instance get --instance "${INSTANCE_ID}")" || {
    log_error "Failed to get details for instance ${INSTANCE_ID}."
    exit 1
  }
  INSTANCE_UDID="$(echo "${GET_INSTANCE_RESPONSE_JSON}" | jq -r '.bootOptions.udid')" || {
    log_error "Failed to parse get details JSON response for instance ${INSTANCE_ID}."
    exit 1
  }
  echo "${INSTANCE_UDID}"
}

is_agent_ready()
{
  local INSTANCE_ID="$1"
  local PROJECT_ID="$2"
  local AGENT_READY_JSON_RESPONSE AGENT_READY_STATUS
  AGENT_READY_JSON_RESPONSE="$(corellium ready --instance "${INSTANCE_ID}" --project "${PROJECT_ID}" 2> /dev/null)" || {
    return 1 # corellium ready exits with nonzero status if agent isn't ready
  }
  AGENT_READY_STATUS="$(echo "${AGENT_READY_JSON_RESPONSE}" | jq -r '.ready')" || {
    log_error 'Failed to parse agent ready JSON response.'
    exit 1
  }
  if [ "${AGENT_READY_STATUS}" = 'true' ]; then
    return 0
  else
    return 1
  fi
}

wait_until_agent_ready()
{
  local INSTANCE_ID="$1"
  local AGENT_READY_SLEEP_TIME='15'
  local INSTANCE_STATUS_ON='on'
  local PROJECT_ID INSTANCE_STATUS
  PROJECT_ID="$(get_project_from_instance_id "${INSTANCE_ID}")"
  INSTANCE_STATUS="$(get_instance_status "${INSTANCE_ID}")"
  while ! is_agent_ready "${INSTANCE_ID}" "${PROJECT_ID}"; do
    case "${INSTANCE_STATUS}" in
      '')
        log_warn "Failed to get instance status. Checking again in ${AGENT_READY_SLEEP_TIME} seconds."
        ;;
      "${INSTANCE_STATUS_ON}")
        log_stdout "Agent is not ready yet. Checking again in ${AGENT_READY_SLEEP_TIME} seconds."
        ;;
      *)
        log_stdout "Instance is ${INSTANCE_STATUS} not ${INSTANCE_STATUS_ON}."
        exit 1
        ;;
    esac
    sleep "${AGENT_READY_SLEEP_TIME}"
    INSTANCE_STATUS="$(get_instance_status "${INSTANCE_ID}")"
  done
  log_stdout 'Virtual device agent is ready.'
}

kill_app()
{
  check_env_vars
  local INSTANCE_ID="$1"
  local APP_BUNDLE_ID="$2"
  if [ "$(is_app_running "${INSTANCE_ID}" "${APP_BUNDLE_ID}")" = 'true' ]; then
    log_stdout "Killing running app ${APP_BUNDLE_ID}."
    if curl --silent -X POST \
      "${CORELLIUM_API_ENDPOINT}/api/v1/instances/${INSTANCE_ID}/agent/v1/app/apps/${APP_BUNDLE_ID}/kill" \
      -H "Accept: application/json" \
      -H "Authorization: Bearer ${CORELLIUM_API_TOKEN}"; then
      log_stdout "Killed running app ${APP_BUNDLE_ID}."
    else
      log_error "Failed to kill app ${APP_BUNDLE_ID}."
      exit 1
    fi
  fi
}

get_project_from_instance_id()
{
  local INSTANCE_ID="$1"
  corellium instance get --instance "${INSTANCE_ID}" | jq -r '.project'
}

install_app_from_url()
{
  local INSTANCE_ID="$1"
  local APP_URL="$2"

  local PROJECT_ID
  PROJECT_ID="$(get_project_from_instance_id "${INSTANCE_ID}")"
  local APP_FILENAME
  APP_FILENAME="$(basename "${APP_URL}")"

  log_stdout "Downloading ${APP_FILENAME}."
  if wget --quiet "${APP_URL}"; then
    log_stdout "Downloaded ${APP_FILENAME}."
  else
    log_error "Failed to downloading app ${APP_FILENAME}."
    exit 1
  fi

  log_stdout "Installing ${APP_FILENAME}."
  if corellium apps install \
    --instance "${INSTANCE_ID}" \
    --project "${PROJECT_ID}" \
    --app "${APP_FILENAME}" > /dev/null; then
    log_stdout "Installed ${APP_FILENAME}."
  else
    log_error "Failed to install app ${APP_FILENAME}."
    exit 1
  fi
}

launch_app()
{
  local INSTANCE_ID="$1"
  local APP_BUNDLE_ID="$2"
  local PROJECT_ID
  PROJECT_ID="$(get_project_from_instance_id "${INSTANCE_ID}")"
  kill_app "${INSTANCE_ID}" "${APP_BUNDLE_ID}"
  log_stdout "Launching app ${APP_BUNDLE_ID}."
  if corellium apps open \
    --instance "${INSTANCE_ID}" \
    --project "${PROJECT_ID}" \
    --bundle "${APP_BUNDLE_ID}" > /dev/null; then
    log_stdout "Launched app ${APP_BUNDLE_ID}."
  else
    log_error "Failed to launch app ${APP_BUNDLE_ID}."
    exit 1
  fi
}

unlock_instance()
{
  local INSTANCE_ID="$1"
  log_stdout "Unlocking instance ${INSTANCE_ID}."
  corellium instance unlock --instance "${INSTANCE_ID}" > /dev/null
  log_stdout "Unlocked instance ${INSTANCE_ID}."
}

is_app_running()
{
  local INSTANCE_ID="$1"
  local APP_BUNDLE_ID="$2"
  local PROJECT_ID
  PROJECT_ID="$(get_project_from_instance_id "${INSTANCE_ID}")"
  corellium apps --project "${PROJECT_ID}" --instance "${INSTANCE_ID}" |
    jq -r --arg id "${APP_BUNDLE_ID}" '.[] | select(.bundleID == $id) | .running'
}

save_vpn_config_to_local_path()
{
  local INSTANCE_ID="$1"
  local VPN_CONFIG_DOWNLOAD_PATH="$2"
  local PROJECT_ID
  PROJECT_ID="$(get_project_from_instance_id "${INSTANCE_ID}")"
  log_stdout "Saving ovpn profile to ${VPN_CONFIG_DOWNLOAD_PATH}."
  corellium project vpnConfig --project "${PROJECT_ID}" --path "${VPN_CONFIG_DOWNLOAD_PATH}"
  log_stdout "Saved ovpn profile to ${VPN_CONFIG_DOWNLOAD_PATH}."
}

wait_for_instance_status()
{
  local INSTANCE_ID="$1"
  local TARGET_INSTANCE_STATUS="$2"
  local SLEEP_TIME_DEFAULT='2'

  case "${TARGET_INSTANCE_STATUS}" in
    'on' | 'off') ;;
    '')
      log_error 'TARGET_INSTANCE_STATUS parameter cannot be empty.'
      exit 1
      ;;
    *)
      log_error "Unsupported target instance status '${TARGET_INSTANCE_STATUS}'."
      exit 1
      ;;
  esac

  local CURRENT_INSTANCE_STATUS
  CURRENT_INSTANCE_STATUS="$(get_instance_status "${INSTANCE_ID}")"
  while [ "${CURRENT_INSTANCE_STATUS}" != "${TARGET_INSTANCE_STATUS}" ]; do
    if [ -z "${CURRENT_INSTANCE_STATUS}" ]; then
      log_warn "Failed to get instance status. Checking again in ${SLEEP_TIME_DEFAULT} seconds."
    fi
    sleep "${SLEEP_TIME_DEFAULT}"
    CURRENT_INSTANCE_STATUS="$(get_instance_status "${INSTANCE_ID}")"
  done
}

install_openvpn_dependencies()
{
  log_stdout 'Installing openvpn.'
  sudo apt-get -qq update
  sudo apt-get -qq install --assume-yes --no-install-recommends openvpn
  if command -v openvpn > /dev/null; then
    log_stdout 'Installed openvpn.'
  else
    log_error 'Failed to install openvpn dependency'
    exit 1
  fi
}

install_adb_dependency()
{
  log_stdout 'Installing adb.'
  sudo apt-get -qq update
  sudo apt-get -qq install adb

  if command -v adb > /dev/null; then
    log_stdout 'Installed adb.'
  else
    log_error 'Failed to install adb dependency'
    exit 1
  fi
}

install_frida_dependencies()
{
  log_stdout 'Installing frida.'
  local TARGET_FRIDA_VERSION='17.2.15'
  python3 -m pip install -U "frida==${TARGET_FRIDA_VERSION}" frida-tools
  log_stdout 'Installed frida.'
  # python3 -m pip install -U objection # Objection does not support Frida 17 yet
}

install_usbfluxd_and_dependencies()
{
  local USBFLUXD_APT_DEPS=(
    avahi-daemon
    build-essential
    git
    libimobiledevice6
    libimobiledevice-utils
    libtool
    pkg-config
    python3-dev
    usbmuxd
  )

  local USBFLUXD_COMPILE_DEP_URLS=(
    'https://github.com/libimobiledevice/libplist'
    'https://github.com/corellium/usbfluxd'
  )

  local USBFLUXD_EXPECTED_BINARIES=(
    usbfluxd
    usbfluxctl
  )

  log_stdout 'Installing usbfluxd apt-get dependencies.'
  sudo apt-get -qq update
  sudo apt-get -qq install --assume-yes --no-install-recommends "${USBFLUXD_APT_DEPS[@]}"
  log_stdout 'Installed usbfluxd apt-get dependencies.'

  log_stdout 'Installing usbfluxd compiled dependencies.'
  local COMPILE_TEMP_DIR COMPILE_DEP_NAME
  COMPILE_TEMP_DIR="$(mktemp -d)"
  cd "${COMPILE_TEMP_DIR}/" || exit 1
  for COMPILE_DEP_URL in "${USBFLUXD_COMPILE_DEP_URLS[@]}"; do
    COMPILE_DEP_NAME="$(basename "${COMPILE_DEP_URL}")"
    log_stdout "Cloning ${COMPILE_DEP_NAME}."
    git clone --quiet "${COMPILE_DEP_URL}" "${COMPILE_DEP_NAME}"
    cd "${COMPILE_TEMP_DIR}/${COMPILE_DEP_NAME}/" || exit 1
    log_stdout "Generating Makefile for ${COMPILE_DEP_NAME}."
    ./autogen.sh > /dev/null 2>&1
    log_stdout "Compiling ${COMPILE_DEP_NAME}."
    make --jobs "$(nproc)" 2>&1 | grep 'Making all in ' || make --jobs "$(nproc)"
    log_stdout "Installing ${COMPILE_DEP_NAME}."
    sudo make install | grep '/usr/bin/install '
    cd "${COMPILE_TEMP_DIR}/" || exit 1
    log_stdout "Deleting build directory for ${COMPILE_DEP_NAME}."
    rm -rf "${COMPILE_DEP_NAME:?}/"
    log_stdout "Installed ${COMPILE_DEP_NAME} and cleaned up build directory."
  done
  log_stdout 'Installed usbfluxd compiled dependencies.'

  for EXPECTED_BINARY in "${USBFLUXD_EXPECTED_BINARIES[@]}"; do
    if command -v "${EXPECTED_BINARY}" > /dev/null; then
      log_stdout "Installed ${EXPECTED_BINARY} at $(command -v "${EXPECTED_BINARY}")."
    else
      log_error "Failed to install ${EXPECTED_BINARY}."
      exit 1
    fi
  done
  cd "${HOME}/" || exit 1
  rm -rf "${COMPILE_TEMP_DIR:?}/"
}

connect_to_vpn_for_instance()
{
  # Run this function with a <= 1 minute timeout
  local INSTANCE_ID="$1"
  local OVPN_CONFIG_PATH="$2"
  local INSTANCE_SERVICES_IP
  INSTANCE_SERVICES_IP="$(get_instance_services_ip "${INSTANCE_ID}")"

  if ! command -v openvpn > /dev/null; then
    log_warn 'Attempting to install openvpn dependency.'
    install_openvpn_dependency
  fi

  save_vpn_config_to_local_path "${INSTANCE_ID}" "${OVPN_CONFIG_PATH}"
  log_stdout 'Connecting to Corellium project VPN.'
  sudo openvpn --config "${OVPN_CONFIG_PATH}" &
  log_stdout 'Connected to Corellium project VPN.'

  # Wait for the tunnel to establish, find the VPN IPv4 address, and test the connection
  until ip addr show tap0 > /dev/null 2>&1; do sleep 0.1; done
  log_stdout 'Found the project VPN tap0 interface.'
  local INSTANCE_VPN_IP
  INSTANCE_VPN_IP="$(ip addr show tap0 | grep 'inet ' | awk '{print $2}' | cut -d'/' -f1)"
  until ping -c1 "${INSTANCE_VPN_IP}"; do sleep 0.1; done
  log_stdout 'Successful ping to the project VPN IP.'
  until ping -c1 "${INSTANCE_SERVICES_IP}"; do sleep 0.1; done
  log_stdout 'Successful ping to the instance services IP.'
}

connect_with_adb()
{
  local INSTANCE_ID="$1"
  local INSTANCE_SERVICES_IP
  INSTANCE_SERVICES_IP="$(get_instance_services_ip "${INSTANCE_ID}")"
  local ADB_CONNECT_PORT='5001'
  local ADB_CONNECT_SOCKET="${INSTANCE_SERVICES_IP}:${ADB_CONNECT_PORT}"

  if ! command -v adb > /dev/null; then
    log_warn 'Attempting to install adb dependency.'
    install_adb_dependency
  fi

  log_stdout "Connecting over adb to ${ADB_CONNECT_SOCKET}."
  adb connect "${ADB_CONNECT_SOCKET}"
  log_stdout "Connected over adb to ${ADB_CONNECT_SOCKET}."
  adb devices -l | grep -q "${ADB_CONNECT_SOCKET}" || {
    log_error "Unable to connect to ${INSTANCE_ID} at ${ADB_CONNECT_SOCKET}."
    adb devices -l
    exit 1
  }
  log_stdout 'Found connected adb device.'
}

run_usbfluxd_and_dependencies()
{
  log_stdout 'Starting usbmuxd service.'
  sudo systemctl start usbmuxd
  sudo systemctl status usbmuxd
  log_stdout 'Started usbmuxd service.'
  log_stdout 'Started avahi-daemon.'
  sudo avahi-daemon &
  log_stdout 'Starting avahi-daemon.'
  log_stdout 'Starting usbfluxd.'
  sudo usbfluxd -f -n &
  log_stdout 'Started usbfluxd.'
}

add_instance_to_usbfluxd()
{
  local INSTANCE_ID="$1"
  local USBFLUXD_PORT='5000'
  local INSTANCE_SERVICES_IP INSTANCE_USBFLUXD_SOCKET
  INSTANCE_SERVICES_IP="$(get_instance_services_ip "${INSTANCE_ID}")"
  INSTANCE_USBFLUXD_SOCKET="${INSTANCE_SERVICES_IP}:${USBFLUXD_PORT}"
  log_stdout "Adding device at ${INSTANCE_USBFLUXD_SOCKET} to usbfluxd."
  usbfluxctl add "${INSTANCE_USBFLUXD_SOCKET}"
  log_stdout "Added device at ${INSTANCE_USBFLUXD_SOCKET} to usbfluxd."
}

verify_usbflux_connection()
{
  local INSTANCE_ID="$1"
  local INSTANCE_UDID
  INSTANCE_UDID="$(get_instance_udid "${INSTANCE_ID}")"
  log_stdout 'Checking for usb connection with idevice_id.'
  until idevice_id "${INSTANCE_UDID}"; do sleep 0.1; done
  log_stdout 'Found usb connection with idevice_id.'
  log_stdout 'Pairing to Corellium device with idevicepair.'
  until idevicepair --udid "${INSTANCE_UDID}" pair; do sleep 1; done
  log_stdout 'Paired to Corellium device with idevicepair.'
  log_stdout 'Validing pairing to Corellium device with idevicepair.'
  idevicepair --udid "${INSTANCE_UDID}" validate || {
    log_error 'Failed to validate that device is paired to host.'
    exit 1
  }
  log_stdout 'Validated pairing to Corellium device with idevicepair.'
}

run_frida_ps_network()
{
  local INSTANCE_ID="$1"
  local GET_INSTANCE_JSON_RESPONSE
  GET_INSTANCE_JSON_RESPONSE="$(corellium instance get --instance "${INSTANCE_ID}")"
  if echo "${GET_INSTANCE_JSON_RESPONSE}" | jq -e '.flavor != ranchu' > /dev/null &&
    ! echo "${GET_INSTANCE_JSON_RESPONSE}" | grep Port | grep -q 27042; then
    log_error "Port 27042 must be forwarded and exposed on instance ${INSTANCE_ID}."
    exit 1
  fi
  local INSTANCE_SERVICES_IP
  INSTANCE_SERVICES_IP="$(get_instance_services_ip "${INSTANCE_ID}")"
  frida-ps -H "${INSTANCE_SERVICES_IP}" -a
}

run_frida_ps_usb()
{
  log_stdout 'Listing running apps.'
  frida-ps --usb --applications || {
    log_warn 'Failed to enumerate running apps. Retrying.'
    frida-ps --usb --applications
  }
  log_stdout 'Listed running apps.'
}

run_frida_script_usb()
{
  local APP_PACKAGE_NAME="$1"
  local FRIDA_SCRIPT_PATH="$2"
  log_stdout "Spawning app ${APP_PACKAGE_NAME} with Frida script $(basename "${FRIDA_SCRIPT_PATH}")."

  if [ "${CI:-false}" = 'true' ]; then
    local FRIDA_TIMEOUT_SECONDS='10'
    log_stdout "Frida script will timeout after ${FRIDA_TIMEOUT_SECONDS} seconds."
    timeout "${FRIDA_TIMEOUT_SECONDS}" \
      frida -U -f "${APP_PACKAGE_NAME}" -l "${FRIDA_SCRIPT_PATH}" || {
      local FAILURE_EXIT_STATUS="$?"
      if [ "${FAILURE_EXIT_STATUS}" -eq 124 ]; then
        log_stdout "Frida successfully timed out after ${FRIDA_TIMEOUT_SECONDS} seconds."
      else
        log_error "Unknown exit status ${FAILURE_EXIT_STATUS}."
        exit 1
      fi
    }
  else
    log_stdout "Frida script will run indefinitely with no timeout."
    frida -U -f "${APP_PACKAGE_NAME}" -l "${FRIDA_SCRIPT_PATH}"
  fi
}
