#!/bin/bash
set -e

# ECE version
CLOUD_ENTERPRISE_VERSION=3.5.1
# Default Docker registry
DOCKER_REGISTRY=docker.elastic.co

# Default Docker namespace
LATEST_VERSIONS_DOCKER_NAMESPACE="cloud-release"
LATEST_STACK_PRE_RELEASE=""

PREVIOUS_VERSIONS_DOCKER_NAMESPACE="cloud-assets"
PREVIOUS_VERSIONS_STACK_PRE_RELEASE="-0"

# Default Docker repository for ECE image
ECE_DOCKER_REPOSITORY=cloud-enterprise

# Default host storage path
HOST_STORAGE_PATH=/mnt/data/elastic

# Get from the client or assume a default location
HOST_DOCKER_HOST=${DOCKER_HOST:-/var/run/docker.sock}

# Enables bootstrapping a client forwarder that uses a tag for the observers
CLIENT_FORWARDER_OBSERVERS_TAG=${CLIENT_FORWARDER_OBSERVERS_TAG:-}

INSTANCE_TYPES_TO_ENABLE=${INSTANCE_TYPES_TO_ENABLE:-}

# Colour codes
YELLOW='\033[0;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

# Exit codes
GENERAL_ERROR_EXIT_CODE=1         # General errors. All errors other than the ones related to either argument or command
UNKNOWN_COMMAND_EXIT_CODE=2       # Unknown command
INVALID_ARGUMENT_EXIT_CODE=3      # Unknown argument or argument's value is not specified
NON_VALID_USER_EXIT_CODE=4        # When starting the installer with a non-valid uid, gid, or group membership
PRECONDITION_NOT_MET_EXIT_CODE=5  # Pre-condition checks that error

# Flag to use when we want the prerequisites to run but not exit when fail
FORCE_INSTALL=false

# Helper flag to indicate that there were failed prerequisites at the host level
HOST_PREREQ_FAILED=false

# Use docker by default, podman if specified
CONTAINER_ENGINE=docker

# By default, when upgrading the platform, upgrader will fail if there are any in flight.
SKIP_PENDING_PLAN_CHECK=false

ENABLE_DEBUG_LOGGING=false

OVERWRITE_EXISTING_IMAGE=false

FORCE_UPGRADE=false

TIMEOUT_FACTOR=1.0

COMMAND=""

COMMAND=help
if [ $# -gt 0 ]; then
    COMMAND=$1
fi

case $COMMAND in
  install )                         shift
                                    ;;
  reset-adminconsole-password )     shift
                                    ;;
  add-stack-version )               shift
                                    ;;
  upgrade )                         shift
                                    ;;
  --help|help )
      echo "================================================================================================"
      echo " Elastic Cloud Enterprise Installation Script v$CLOUD_ENTERPRISE_VERSION"
      echo "================================================================================================"
      echo ""
      echo "${0##*/} [COMMAND] {OPTIONS}"
      echo ""
      echo "Available commands:"
      echo "  install                        Installs Elastic Cloud Enterprise on the host"
      echo "                                 This is the default command"
      echo ""
      echo "  upgrade                        Upgrades the Elastic Cloud Enterprise installation to $CLOUD_ENTERPRISE_VERSION"
      echo ""
      echo "  reset-adminconsole-password    Resets the password for an administration console user"
      echo ""
      echo "  add-stack-version              Make a new Elastic Stack version available"
      echo ""
      echo "For available arguments run command with '--help' argument"
      echo "================================================================================================"
      exit 0
      ;;
  *)
    if [[ $1 == --* ]]; then
      COMMAND="install"
    else
      echo -e "${RED}Unknown command '$COMMAND'${NC}"
      exit $UNKNOWN_COMMAND_EXIT_CODE
    fi
    ;;
esac

# Checks 3rd parameter (argument' value) for empty string or a string that starts with '--'
# if the string meet the conditions, the function forces the script to exit with code 3
# Otherwise, it assigns the argument's value to a variable whose name is passed as the first parameter
# Parameters:
#  $1 - a name of variable to assign the argument's value to
#  $2 - a name of the argument
#  $3 - argument's value
setArgument() {
  if [[ $3 == --* ]] || [[ -z "${3}" ]]; then
    echo -e "${RED}Argument '$2' does not have a value${NC}"
    exit $INVALID_ARGUMENT_EXIT_CODE
  else
    local  __resultvar=$1
    eval $__resultvar="'$3'"
  fi
}

# Same as the setArgument but perform some filtering on the input value before
# doing any assignment
setArgumentWithFilter() {
  local _value=$3
  if [[ "${_value}" == *"unix://"* ]]; then
    local _value=${_value:7}
  fi
  setArgument $1 $2 ${_value}
}

# Verify that the running user has an allowable UID (not in the
# reserved range of 0-999) in order to avoid UID collision with the
# internal docker image's users. Additionally, verify that the user is
# a member of the docker group (or can run docker commands).
validateRunningUser(){
  local uuid=$(id -ru)
  local guid=$(id -rg)
  if [[ $uuid -lt 1000 || $guid -lt 1000 ]]; then
    # Only stating the problem. Don't want to suggest the user modifies UIDs or GIDs
    echo -e "${RED}The UID or GID must not be smaller than 1000.${NC}"
    exit $NON_VALID_USER_EXIT_CODE
  fi

  # check whether they can successfully run a trivial docker command
  local can_run_docker=false
  if docker ps > /dev/null 2>&1; then
    can_run_docker=true
  fi

  # check whether they're actually in the literal docker group
  local docker_group=$(id -nG | grep -E '(^|\s)docker($|\s)')
  local is_in_docker_group=false
  if [ -n "$docker_group" ]; then
    is_in_docker_group=true
  fi

  if [[ "$can_run_docker" == "false" ]]; then
    if [[ "$is_in_docker_group" == "false" ]]; then
      echo -e "${YELLOW}The user is not a member of the docker group.${NC}"
    fi

    if [[ "${FORCE_INSTALL}" == "false" ]]; then
      echo -e "${RED}To resolve the issue, add the user to the docker group or install as a different user.${NC}"
      exit $NON_VALID_USER_EXIT_CODE
    fi
  fi
}

dockerCmdViaSocket() {
    case "$CONTAINER_ENGINE" in
        docker )  docker -H "unix://${HOST_DOCKER_HOST}" "$@"
                  ;;
        podman )  podman-remote --url "unix://${HOST_DOCKER_HOST}" "$@"
                  ;;
        *)        echo -e "${RED}Unknown argument '$1'${NC}"
                  exit $INVALID_ARGUMENT_EXIT_CODE
                  ;;
    esac
}

parseInstallArguments() {
  while [ "$1" != "" ]; do
    case $1 in
      --coordinator-host )            setArgument COORDINATOR_HOST $1 $2
                                      shift
                                      ;;
      --host-docker-host )            setArgumentWithFilter HOST_DOCKER_HOST $1 $2
                                      shift
                                      ;;
      --host-storage-path )           setArgument HOST_STORAGE_PATH $1 $2
                                      shift
                                      ;;
      --cloud-enterprise-version )    setArgument CLOUD_ENTERPRISE_VERSION $1 $2
                                      shift
                                      ;;
      --debug )                       ENABLE_DEBUG_LOGGING=true
                                      ;;
      --docker-registry )             setArgument DOCKER_REGISTRY $1 $2
                                      shift
                                      ;;
      --latest-stack-pre-release )    setArgument LATEST_STACK_PRE_RELEASE $1 $2
                                      if [[ ${LATEST_STACK_PRE_RELEASE::1} != "-" ]]
                                      then
                                        LATEST_STACK_PRE_RELEASE="-"$LATEST_STACK_PRE_RELEASE; fi
                                      shift
                                      ;;
      --previous-stack-pre-release )  setArgument PREVIOUS_VERSIONS_STACK_PRE_RELEASE $1 $2
                                      if [[ ${PREVIOUS_VERSIONS_STACK_PRE_RELEASE::1} != "-" ]]
                                      then
                                      PREVIOUS_VERSIONS_STACK_PRE_RELEASE="-"$PREVIOUS_VERSIONS_STACK_PRE_RELEASE; fi
                                      PREVIOUS_VERSIONS_DOCKER_NAMESPACE="cloud-ci"
                                      shift
                                      ;;
      --ece-docker-repository )       setArgument ECE_DOCKER_REPOSITORY $1 $2
                                      shift
                                      ;;
      --overwrite-existing-image )    OVERWRITE_EXISTING_IMAGE=true
                                      ;;
      --runner-id )                   setArgument RUNNER_ID $1 $2
                                      shift
                                      ;;
      --roles )                       setArgument RUNNER_ROLES $1 $2
                                      shift
                                      ;;
      --roles-token )                 setArgument RUNNER_ROLES_TOKEN $1 $2
                                      shift
                                      ;;
      --host-ip )                     setArgument HOST_IP $1 $2
                                      shift
                                      ;;
      --external-hostname )           setArgument RUNNER_EXTERNAL_HOSTNAME $1 $2
                                      shift
                                      ;;
      --availability-zone )           setArgument AVAILABILITY_ZONE $1 $2
                                      shift
                                      ;;
      --capacity )                    setArgument CAPACITY $1 $2
                                      shift
                                      ;;
      --memory-settings )             setArgument MEMORY_SETTINGS $1 $2
                                      shift
                                      ;;
      --environment-metadata )        setArgument RUNNER_ENVIRONMENT_METADATA_JSON $1 $2
                                      shift
                                      ;;
      --config-file )                 setArgument CONFIG_FILE $1 $2
                                      shift
                                      ;;
      --client-forwarder-observers-tag )              setArgument CLIENT_FORWARDER_OBSERVERS_TAG $1 $2
                                      shift
                                      ;;
      --allocator-tags )              setArgument ALLOCATOR_TAGS $1 $2
                                      shift
                                      ;;
      --proxy-tags )                  setArgument PROXY_TAGS $1 $2
                                      shift
                                      ;;
      --timeout-factor )              setArgument TIMEOUT_FACTOR $1 $2
                                      shift
                                      ;;
      --force )                       FORCE_INSTALL=true
                                      ;;
      --api-base-url )                setArgument API_BASE_URL $1 $2
                                      shift
                                      ;;
      --podman )                      CONTAINER_ENGINE=podman
                                      ;;
      --help|help)
                        echo "Installs Elastic Cloud Enterprise according to the specified parameters, "
                        echo "both to start a new installation and to add hosts to an existing installation."
                        echo "Can be used to automate installation or to customize how you install platform."
                        echo ""
                        echo "elastic-cloud-enterprise.sh install [--coordinator-host C_HOST_IP]"
                        echo "[--host-docker-host HOST_DOCKER_HOST] [--host-storage-path PATH_NAME]"
                        echo "[--cloud-enterprise-version VERSION_NAME] [--debug] [--docker-registry DOCKER_REGISTRY]"
                        echo "[--overwrite-existing-image] [--runner-id ID] [--host-ip HOST_IP]"
                        echo "[--availability-zone ZONE_NAME] [--capacity MB_VALUE] [--memory-settings JVM_SETTINGS]"
                        echo "[--roles-token TOKEN] [--roles \"ROLES\"] [--force] [--api-base-url API_BASE_URL] [--podman]"
                        echo ""
                        echo "Arguments:"
                        echo "--coordinator-host         Specifies the IP address of the first host used to"
                        echo "                           start a new Elastic Cloud Enterprise installation."
                        echo "                           Must be specified when installing on additional"
                        echo "                           hosts to add them to an existing installation."
                        echo ""
                        echo "--host-docker-host         Set the docker's docker-host location"
                        echo "                           Defaults to /var/run/docker.sock"
                        echo ""
                        echo "--host-storage-path        Specifies the host storage path used by "
                        echo "                           the installation."
                        echo "                           Defaults to '$HOST_STORAGE_PATH'"
                        echo ""
                        echo "--cloud-enterprise-version Specifies the version of Elastic Cloud Enterprise "
                        echo "                           to install."
                        echo "                           Defaults to '$CLOUD_ENTERPRISE_VERSION'"
                        echo ""
                        echo "--debug                    Outputs debugging information during installation."
                        echo "                           Defaults to false."
                        echo ""
                        echo "--allocator-tags           Specifies a comma delimited string of tags that are assigned"
                        echo "                           to this allocator."
                        echo "                           The format for ALLOCATOR_TAGS is tag_name:tag_value,tag_name:tag_value"
                        echo "                           Defaults to ''."
                        echo ""
                        echo "--timeout-factor           Multiplies timeouts used during installation by this number."
                        echo "                           Use if installation fails due to timeout."
                        echo "                           Defaults to $TIMEOUT_FACTOR."
                        echo ""
                        echo "--docker-registry          Specifies the Docker registry for the Elastic "
                        echo "                           Cloud Enterprise assets."
                        echo "                           Defaults to '$DOCKER_REGISTRY'"
                        echo ""
                        echo "--overwrite-existing-image Overwrites any existing local image when retrieving"
                        echo "                           the Elastic Cloud Enterprise installation image from"
                        echo "                           the Docker repository."
                        echo "                           Defaults to false."
                        echo ""
                        echo "--runner-id                Assigns an arbitrary ID to the host (runner) that you"
                        echo "                           are installing Elastic Cloud Enterprise on."
                        echo "                           Defaults to 'host-ip'"
                        echo ""
                        echo "--host-ip                  Specifies an IP address for the host that you are"
                        echo "                           installing Elastic Cloud Enterprise on. Used for"
                        echo "                           internal communication within the cluster. This must"
                        echo "                           be a routable IP in your network."
                        echo "                           Defaults to the IP address for the network interface"
                        echo ""
                        echo "--availability-zone        Specifies an availability zone for the host that you"
                        echo "                           are installing Elastic Cloud Enterprise on."
                        echo "                           Defaults to 'ece-zone-1'"
                        echo ""
                        echo "--capacity                 Specifies the amount of RAM in megabytes this runner"
                        echo "                           makes available for Elasticsearch clusters."
                        echo "                           Must be at least 8192 MB."
                        echo "                           Defaults to 85% of available RAM, if the remaining 15%"
                        echo "                           is less than 28GB. Otherwise, 28GB is subtracted from the"
                        echo "                           total and the remainder is used."
                        echo "                           if you specified --roles allocator 12GB is subtracted "
                        echo "                           instead of 28GB"
                        echo ""
                        echo "--memory-settings          Specifies a custom JVM setting for a service, such as"
                        echo "                           heap size. Settings must be specified in JSON format."
                        echo ""
                        echo "--roles-token              Specifies a token that enables the host to join an"
                        echo "                           existing Elastic Cloud Enterprise installation."
                        echo "                           Required when '--coordinator-host' is also specified."
                        echo ""
                        echo "--roles                    Assigns a comma-separated list of runner roles to the"
                        echo "                           host during installation."
                        echo "                           Supported: director, coordinator, allocator, proxy"
                        echo ""
                        echo "--force                    Checks the installation requirements, but does not "
                        echo "                           exit the installation process if a check fails. "
                        echo "                           If not specified, a failed installation check "
                        echo "                           causes the installation process to exit"
                        echo ""
                        echo "--external-hostname        Comma separated list of names to include in the SAN"
                        echo "                           extension of the self generated TLS certificates for HTTP. "
                        echo ""
                        echo "--api-base-url             Specifies the base URL for the API. Used for determining"
                        echo "                           the ServiceProvider-initiated login redirect endpoint"
                        echo "                           This must be externally accessible."
                        echo "                           Defaults to 'https://api-docker-host-ip:12300'"
                        echo ""
                        echo "--podman                   Use podman as container engine instead of docker"
                        echo ""
                        echo "For the full description of every command see documentation"
                        echo ""
                        exit 0
                        ;;
       *)  echo -e "${RED}Unknown argument '$1'${NC}"
           exit $INVALID_ARGUMENT_EXIT_CODE
           ;;
    esac
    shift
  done
}

parseResetAdminconsolePasswordArguments() {
  SOURCE_CONTAINER_NAME="frc-runners-runner"
  ZK_ROOT_PASSWORD=""
  USER=""
  NEW_PWD=""
  SECRETS_RELATIVE_PATH="/bootstrap-state/bootstrap-secrets.json"

  while [ "$1" != "" ]; do
    case $1 in
        --host-docker-host )          setArgumentWithFilter HOST_DOCKER_HOST $1 $2
                                      shift
                                      ;;
        --podman )                    CONTAINER_ENGINE=podman
                                      ;;
        --secrets )                   setArgument BOOTSTRAP_SECRETS $1 $2
                                      BOOTSTRAP_SECRETS=$(cd "$(dirname "$BOOTSTRAP_SECRETS")"; pwd)/$(basename "$BOOTSTRAP_SECRETS")
                                      shift
                                      ;;
        --pwd )                       setArgument NEW_PWD $1 $2
                                      NEW_PWD="--pwd $NEW_PWD"
                                      shift
                                      ;;
        --user )                      setArgument USER $1 $2
                                      USER="--user $USER"
                                      shift
                                      ;;
        --host-storage-path )         setArgument HOST_STORAGE_PATH $1 $2
                                      shift
                                      ;;
        --podman )                    CONTAINER_ENGINE=podman
                                      ;;
        --help|help )     echo "============================================================================================="
                          echo "Reset the password for an administration console user."
                          echo "The script should be run on either the first host you installed Elastic Cloud"
                          echo "Enterprise on or a host that holds the director role."
                          echo ""
                          echo "${0##*/} reset-adminconsole-password [--host-docker-host HOST_DOCKER_HOST] [--user USER_NAME]"
                          echo "[--pwd NEW_PASSWORD] [--host-storage-path PATH_NAME] [--secrets PATH_TO_SECRETS_FILE] [--podman]"
                          echo "[[--]help]"
                          echo ""
                          echo "Arguments:"
                          echo ""
                          echo "--host-docker-host   Set the docker's docker-host location"
                          echo "                     Defaults to /var/run/docker.sock"
                          echo ""
                          echo "--user               Specifies the name of a user whose password needs to be"
                          echo "                     changed. Defaults to 'admin'"
                          echo ""
                          echo "--pwd                Specifies a new password for the selected user. If it is"
                          echo "                     not specified, a new password will be generated"
                          echo ""
                          echo "--host-storage-path  Specifies the host storage path used by the Elastic Cloud"
                          echo "                     Enterprise installation. It is used for calculating"
                          echo "                     a location of the default file with secrets as well as"
                          echo "                     location of a log file."
                          echo "                     Defaults to '$HOST_STORAGE_PATH'"
                          echo ""
                          echo "--secrets            Specifies a path to a file with secrets. The file will be"
                          echo "                     updated with a new password."
                          echo "                     Defaults to '\$HOST_STORAGE_PATH$SECRETS_RELATIVE_PATH'"
                          echo ""
                          echo "--podman             Use podman as container engine instead of docker"
                          echo ""
                          echo "Example:"
                          echo "${0##*/} reset-adminconsole-password --user admin --pwd new-very-strong-password"
                          echo ""
                          exit 0
                          ;;
       *)  echo -e "${RED}Unknown argument '$1'${NC}"
           exit $INVALID_ARGUMENT_EXIT_CODE
           ;;
    esac
    shift
  done

  DEFAULT_BOOTSTRAP_SECRETS="$HOST_STORAGE_PATH$SECRETS_RELATIVE_PATH"

  if [[ -z "$BOOTSTRAP_SECRETS" ]]; then
      # if neither bootstrap secrets file nor root password are specified, try find secrets file by the default path
      if [[ -e "$DEFAULT_BOOTSTRAP_SECRETS" ]]; then
        echo -e "A bootstrap secrets file was found using the default path${NC}"
        BOOTSTRAP_SECRETS=$DEFAULT_BOOTSTRAP_SECRETS
      fi
  else
      if [[ ! -e "$BOOTSTRAP_SECRETS" ]]; then
        echo -e "${RED}A bootstrap secrets file was not found using path '$BOOTSTRAP_SECRETS'${NC}"
        exit $INVALID_ARGUMENT_EXIT_CODE
      fi

      if [[ ! -r ${BOOTSTRAP_SECRETS} ]]; then
        echo -e "${RED}Secrets file '${BOOTSTRAP_SECRETS}' doesn't have read permissions for the current user.${NC}"
        exit $INVALID_ARGUMENT_EXIT_CODE
      fi
  fi

  if [[ -z "$BOOTSTRAP_SECRETS" ]]; then
      # pull password for zookeeper from director's container
      ZK_ROOT_PASSWORD=$(dockerCmdViaSocket exec frc-directors-director bash -c 'echo -n $FOUND_ZK_READWRITE' 2>/dev/null | cut -d: -f 2)
      if [[ -z "$ZK_ROOT_PASSWORD" ]]; then
        echo -e "${RED}Failed to get access to Elastic Cloud Enterprise.${NC}"
        echo -e "Please meet at least one of the following requirements:"
        echo -e " - Run the script on the first host you installed Elastic Cloud Enterprise on"
        echo -e "   using either default or custom path to secrets file"
        echo -e " - Run the script on an Elastic Cloud Enterprise host that holds"
        echo -e "   the director role"
        exit $INVALID_ARGUMENT_EXIT_CODE
      else
        echo -e "Use director's settings to access Elastic Cloud Enterprise environment"
      fi
  fi
}

parseUpgradeArguments() {
  OVERWRITE_EXISTING_IMAGE=false

  while [ "$1" != "" ]; do
    case $1 in
        --debug )                     ENABLE_DEBUG_LOGGING=true
                                      ;;
        --host-docker-host )          setArgumentWithFilter HOST_DOCKER_HOST $1 $2
                                      shift
                                      ;;
        --docker-registry )           setArgument DOCKER_REGISTRY $1 $2
                                      shift
                                      ;;
        --ece-docker-repository )     setArgument ECE_DOCKER_REPOSITORY $1 $2
                                      shift
                                      ;;
        --overwrite-existing-image )  OVERWRITE_EXISTING_IMAGE=true
                                      ;;
        --skip-pending-plan-check )   SKIP_PENDING_PLAN_CHECK=true
                                      ;;
        --cloud-enterprise-version )  setArgument CLOUD_ENTERPRISE_VERSION $1 $2
                                      shift
                                      ;;
        --timeout-factor )            setArgument TIMEOUT_FACTOR $1 $2
                                      shift
                                      ;;
        --api-base-url )              setArgument API_BASE_URL $1 $2
                                      shift
                                      ;;
        --podman )                    CONTAINER_ENGINE=podman
                                      ;;
        --force-upgrade )             FORCE_UPGRADE=true
                                      ;;
        --help|help )     echo "=========================================================================================="
                          echo "Upgrades current Elastic Cloud Installation to version $CLOUD_ENTERPRISE_VERSION."
                          echo "The script should be run on either the first host you installed Elastic Cloud"
                          echo "Enterprise on or a host that holds the director role."
                          echo ""
                          echo "${0##*/} upgrade [--host-docker-host HOST_DOCKER_HOST] [--docker-registry DOCKER_REGISTRY]"
                          echo "[--overwrite-existing-image]  [--skip-pending-plan-check] [--debug] [--api-base-url API_BASE_URL]"
                          echo "[--podman] [[--]help]"
                          echo ""
                          echo "Arguments:"
                          echo ""
                          echo ""
                          echo "--host-docker-host         Set the docker's docker-host location"
                          echo "                           Defaults to /var/run/docker.sock"
                          echo ""
                          echo "--docker-registry          Specifies the Docker registry for the Elastic "
                          echo "                           Cloud Enterprise assets."
                          echo "                           Defaults to '$DOCKER_REGISTRY'"
                          echo ""
                          echo "--overwrite-existing-image If specified, overwrites any existing local image when"
                          echo "                           retrieving the Elastic Cloud Enterprise installation"
                          echo "                           image from the repository."
                          echo ""
                          echo "--skip-pending-plan-check  Forces upgrade to proceed if there are pending plans found before install."
                          echo "                           Defaults to false."
                          echo ""
                          echo "--debug                    If specified, outputs debugging information during"
                          echo "                           upgrade"
                          echo ""
                          echo "--timeout-factor           Multiplies timeouts used during upgrade by this number."
                          echo "                           Use if upgrade fails due to timeout."
                          echo "                           Defaults to $TIMEOUT_FACTOR."
                          echo ""
                          echo "--api-base-url             Specifies the base URL for the API. Used for determining"
                          echo "                           the ServiceProvider-initiated login redirect endpoint"
                          echo "                           This must be externally accessible."
                          echo "                           Defaults to 'https://api-docker-host-ip:12300'"
                          echo ""
                          echo "--podman                   Use podman as container engine instead of docker"
                          echo ""
                          echo "--force-upgrade            Makes the ECE upgrader overwrite any remaining status from "
                          echo "                           ongoing previous upgrades. If not specified, the ECE upgrader "
                          echo "                           will re-attach to the existing upgrade process. "
                          echo "                           Useful e.g. in cases when previous upgrades got stuck due to "
                          echo "                           infrastructure problems and can't be resumed."
                          echo ""
                          echo "Example:"
                          echo "${0##*/} upgrade"
                          echo ""
                          exit 0
                          ;;
       *)  echo -e "${RED}Unknown argument '$1'${NC}"
           exit $INVALID_ARGUMENT_EXIT_CODE
           ;;
    esac
    shift
  done

  SOURCE_CONTAINER_NAME="frc-runners-runner"
  HOST_STORAGE_PATH=$(dockerCmdViaSocket exec $SOURCE_CONTAINER_NAME bash -c 'echo -n $HOST_STORAGE_PATH' 2>/dev/null | cut -d: -f 2)
  if [[ -z "${HOST_STORAGE_PATH}" ]]; then
      echo -e "${RED}Container $SOURCE_CONTAINER_NAME was not found -- is the environment running?${NC}"
      exit $GENERAL_ERROR_EXIT_CODE
  fi

  SOURCE_CONTAINER_NAME="frc-directors-director"
  ZK_ROOT_PASSWORD=$(dockerCmdViaSocket exec $SOURCE_CONTAINER_NAME bash -c 'echo -n $FOUND_ZK_READWRITE' 2>/dev/null | cut -d: -f 2)
  if [[ -z "${ZK_ROOT_PASSWORD}" ]]; then
      echo -e "${RED}Container $SOURCE_CONTAINER_NAME was not found -- does the current host have a role 'director'?${NC}"
      exit $GENERAL_ERROR_EXIT_CODE
  fi
}

resetAdminconsolePassword() {
  CLOUD_IMAGE=$(dockerCmdViaSocket inspect -f '{{ .Config.Image }}' $SOURCE_CONTAINER_NAME)

  if [[ ! -z "${BOOTSTRAP_SECRETS}" ]]; then
    SECRETS_FILE_NAME="/secrets.json"
    MNT="-v ${BOOTSTRAP_SECRETS}:${SECRETS_FILE_NAME}:rw"
    SECRETS_ARG="--secrets ${SECRETS_FILE_NAME}"
  fi

  if [[ ! -z "${CLOUD_IMAGE}" ]]; then
    dockerCmdViaSocket run \
        --env ZK_AUTH=$ZK_ROOT_PASSWORD \
        $(dockerCmdViaSocket inspect -f '{{ range .HostConfig.ExtraHosts }} --add-host {{.}} {{ end }}' $SOURCE_CONTAINER_NAME) \
        $MNT \
        -v "$HOST_STORAGE_PATH/logs":"/app/logs" \
        --rm $CLOUD_IMAGE \
        /elastic_cloud_apps/bootstrap/reset_adminconsole_password/reset-adminconsole-password.sh $USER $NEW_PWD $SECRETS_ARG # run directly, bypass runit
  else
      echo -e "${RED}Container $SOURCE_CONTAINER_NAME was not found -- is the environment running?${NC}"
      exit $GENERAL_ERROR_EXIT_CODE
  fi
}

addStackVersion() {
  # We expect metadata in the stackpack to indicate whether it's compatible with this version of ECE
  # It's also the adminconsole's responsibility to do any verification of signatures etc. in the future

  CLOUD_IMAGE=$(dockerCmdViaSocket inspect -f '{{ .Config.Image }}' $SOURCE_CONTAINER_NAME)

  if [[ ! -z "${BOOTSTRAP_SECRETS}" ]]; then
    SECRETS_FILE_NAME="/secrets.json"
    MNT="-v ${BOOTSTRAP_SECRETS}:${SECRETS_FILE_NAME}:ro"
  fi

  if [[ ! -z "${CLOUD_IMAGE}" ]]; then
    if [[ -e "${VERSION}.zip" ]]; then
      # Local stack pack zip exists, let's process that
      echo -e "Found a local ${VERSION}.zip stack pack. This will be used in processing the stack pack."

      ADD_STACKPACK_RESULTS=$(dockerCmdViaSocket run \
        --env USER=$USER \
        --env PASS=$PASS \
        --env SECRETS_FILE_NAME=$SECRETS_FILE_NAME \
        --env VERSION=$VERSION \
        $(dockerCmdViaSocket inspect -f '{{ range .HostConfig.ExtraHosts }} --add-host {{.}} {{ end }}' $SOURCE_CONTAINER_NAME) \
        $MNT \
        -v "$HOST_STORAGE_PATH/logs":"/app/logs" \
        -v "${PWD}/${VERSION}.zip":"/tmp/${VERSION}.zip" \
        --rm $CLOUD_IMAGE \
        bash -c 'wget -q -O - --content-on-error --auth-no-challenge \
                   --header "Content-Type: application/zip" \
                   --user $USER \
                   --password ${PASS:-$(jq -r .adminconsole_root_password $SECRETS_FILE_NAME)} \
                   --post-file=/tmp/${VERSION}.zip \
                   http://containerhost:12400/api/v1/stack/versions') \
        && echo "Stack version ${VERSION} added from local stack pack" \
        || echo -e "${RED}Could not add stack version ${VERSION} from local stack pack${ADD_STACKPACK_RESULTS:+\n$ADD_STACKPACK_RESULTS}${NC}"
    else
      # Local stack pack zip doesn't exist, we'll attempt to download the file

      # Let's check that we can access the stack pack
      if wget -q --spider --timeout=60 "https://download.elastic.co/cloud-enterprise/versions/${VERSION}.zip"; then
        ADD_STACKPACK_RESULTS=$(dockerCmdViaSocket run \
          --env USER=$USER \
          --env PASS=$PASS \
          --env SECRETS_FILE_NAME=$SECRETS_FILE_NAME \
          --env VERSION=$VERSION \
          $(dockerCmdViaSocket inspect -f '{{ range .HostConfig.ExtraHosts }} --add-host {{.}} {{ end }}' $SOURCE_CONTAINER_NAME) \
          $MNT \
          -v "$HOST_STORAGE_PATH/logs":"/app/logs" \
          --rm $CLOUD_IMAGE \
          bash -c 'wget -qO /tmp/${VERSION}.zip --timeout=120 https://download.elastic.co/cloud-enterprise/versions/${VERSION}.zip \
                   && wget -q -O - --content-on-error --auth-no-challenge \
                        --header "Content-Type: application/zip" \
                        --user $USER \
                        --password ${PASS:-$(jq -r .adminconsole_root_password $SECRETS_FILE_NAME)} \
                        --post-file=/tmp/${VERSION}.zip \
                        http://containerhost:12400/api/v1/stack/versions') \
          && echo "Stack version ${VERSION} added" \
          || echo -e "${RED}Could not add stack version ${VERSION}${ADD_STACKPACK_RESULTS:+\n$ADD_STACKPACK_RESULTS}${NC}"
      else
        echo -e "${RED}Could not download stack pack https://download.elastic.co/cloud-enterprise/versions/${VERSION}.zip, please check the version and network connectivity${NC}"
        exit $GENERAL_ERROR_EXIT_CODE
      fi
    fi
  else
      echo -e "${RED}Container $SOURCE_CONTAINER_NAME was not found -- is the environment running?${NC}"
      exit $GENERAL_ERROR_EXIT_CODE
  fi
}

runUpgradeContainer() {
  # only run with --tty if standard input is a tty
  DOCKER_TTY=""
  if [ -t 0 ]; then
      DOCKER_TTY="--tty"
  fi

  if [ -n "${API_BASE_URL}" ]; then
      DOCKER_ADDITIONAL_ARGUMENTS="--env ECE_ADMIN_CONSOLE_API_BASE_URL=${API_BASE_URL} ${DOCKER_ADDITIONAL_ARGUMENTS}"
  fi

  dockerCmdViaSocket run \
      ${DOCKER_ADDITIONAL_ARGUMENTS} \
      --env HOST_DOCKER_HOST=${HOST_DOCKER_HOST} \
      --env HOST_STORAGE_PATH=${HOST_STORAGE_PATH} \
      --env CLOUD_ENTERPRISE_VERSION=${CLOUD_ENTERPRISE_VERSION} \
      --env SKIP_PENDING_PLAN_CHECK=${SKIP_PENDING_PLAN_CHECK} \
      --env ENABLE_DEBUG_LOGGING=${ENABLE_DEBUG_LOGGING} \
      --env DOCKER_REGISTRY=${DOCKER_REGISTRY} \
      --env ECE_DOCKER_REPOSITORY=${ECE_DOCKER_REPOSITORY} \
      --env ECE_TIMEOUT_FACTOR=${TIMEOUT_FACTOR} \
      --env FORCE_UPGRADE=${FORCE_UPGRADE} \
      -v ${HOST_DOCKER_HOST}:/run/docker.sock \
      -v ${HOST_STORAGE_PATH}:${HOST_STORAGE_PATH} \
      --name elastic-cloud-enterprise-installer \
      --rm -i ${DOCKER_TTY} ${DOCKER_REGISTRY}/${ECE_DOCKER_REPOSITORY}/elastic-cloud-enterprise:${CLOUD_ENTERPRISE_VERSION} elastic-cloud-enterprise-upgrader
}

createAndValidateHostStoragePath() {
  uid=`id -u`
  gid=`id -g`

  if [[ ! -e ${HOST_STORAGE_PATH} ]]; then
    mkdir -p ${HOST_STORAGE_PATH}
    chown -R $uid:$gid ${HOST_STORAGE_PATH}
  fi

  if [[ ! -r ${HOST_STORAGE_PATH} ]]; then
    printf "${RED}%s${NC}\n" "Host storage path ${HOST_STORAGE_PATH} exists but doesn't have read permissions for user '${USER}'."
    printf "${RED}%s${NC}\n" "Please supply the correct permissions for the host storage path."
    exit $GENERAL_ERROR_EXIT_CODE
  fi

  if [[ ! -w ${HOST_STORAGE_PATH} ]]; then
    printf "${RED}%s${NC}\n" "Host storage path ${HOST_STORAGE_PATH} exists but doesn't have write permissions for user '${USER}'."
    printf "${RED}%s${NC}\n" "Please supply the correct permissions for the host storage path."
    exit $GENERAL_ERROR_EXIT_CODE
  fi

  export HOST_STORAGE_DEVICE_PATH=$(df --output=source ${HOST_STORAGE_PATH} | sed 1d)
}

runBootstrapInitiatorContainer() {
  # only run with --tty if standard input is a tty
  DOCKER_TTY=""
  if [ -t 0 ]; then
      DOCKER_TTY="--tty"
  fi

  if [ -n "${RUNNER_EXTERNAL_HOSTNAME}" ]; then
      DOCKER_ADDITIONAL_ARGUMENTS="--env RUNNER_EXTERNAL_HOSTNAME=${RUNNER_EXTERNAL_HOSTNAME} --env HOST_DNS_NAMES=${RUNNER_EXTERNAL_HOSTNAME} ${DOCKER_ADDITIONAL_ARGUMENTS}"
  fi

  if [ -n "${API_BASE_URL}" ]; then
      DOCKER_ADDITIONAL_ARGUMENTS="--env ECE_ADMIN_CONSOLE_API_BASE_URL=${API_BASE_URL} ${DOCKER_ADDITIONAL_ARGUMENTS}"
  fi

  FLAGS=$(env | while read ENV_VAR; do if [[ ${ENV_VAR} == CLOUD_FEATURE* ]]; then printf -- "--env ${ENV_VAR} "; fi; done)

  # binding for port 20000 is left for backward compatibility with 1.1.x and lower.
  dockerCmdViaSocket run \
      ${DOCKER_ADDITIONAL_ARGUMENTS} \
      --env RUNNER_ENVIRONMENT_METADATA_JSON=${RUNNER_ENVIRONMENT_METADATA_JSON:-{}} \
      --env COORDINATOR_HOST=${COORDINATOR_HOST} \
      --env HOST_DOCKER_HOST=${HOST_DOCKER_HOST} \
      --env HOST_STORAGE_PATH=${HOST_STORAGE_PATH} \
      --env HOST_STORAGE_DEVICE_PATH=${HOST_STORAGE_DEVICE_PATH} \
      --env CLOUD_ENTERPRISE_VERSION=${CLOUD_ENTERPRISE_VERSION} \
      --env ENABLE_DEBUG_LOGGING=${ENABLE_DEBUG_LOGGING} \
      --env DOCKER_REGISTRY=${DOCKER_REGISTRY} \
      --env LATEST_VERSIONS_DOCKER_NAMESPACE=${LATEST_VERSIONS_DOCKER_NAMESPACE} \
      --env LATEST_STACK_PRE_RELEASE=${LATEST_STACK_PRE_RELEASE} \
      --env PREVIOUS_VERSIONS_DOCKER_NAMESPACE=${PREVIOUS_VERSIONS_DOCKER_NAMESPACE} \
      --env PREVIOUS_VERSIONS_STACK_PRE_RELEASE=${PREVIOUS_VERSIONS_STACK_PRE_RELEASE} \
      --env ECE_DOCKER_REPOSITORY=${ECE_DOCKER_REPOSITORY} \
      --env RUNNER_ID=${RUNNER_ID} \
      --env RUNNER_ROLES=${RUNNER_ROLES} \
      --env RUNNER_ROLES_TOKEN=${RUNNER_ROLES_TOKEN} \
      --env CLIENT_FORWARDER_OBSERVERS_TAG=${CLIENT_FORWARDER_OBSERVERS_TAG:-""} \
      --env ALLOCATOR_TAGS=${ALLOCATOR_TAGS:-""} \
      --env PROXY_TAGS=${PROXY_TAGS:-""} \
      --env HOST_IP=${HOST_IP} \
      --env AVAILABILITY_ZONE=${AVAILABILITY_ZONE} \
      --env CAPACITY=${CAPACITY} \
      --env ROLE="bootstrap-initiator" \
      --env UID=`id -u` \
      --env GID=`id -g` \
      --env MEMORY_SETTINGS=${MEMORY_SETTINGS} \
      --env CONFIG_FILE=${CONFIG_FILE} \
      --env FORCE_INSTALL=${FORCE_INSTALL} \
      --env HOST_PREREQ_FAILED=${HOST_PREREQ_FAILED} \
      --env ECE_TIMEOUT_FACTOR=${TIMEOUT_FACTOR} \
      --env HOST_KERNEL_PARAMETERS="${HOST_KERNEL_PARAMETERS}" \
      --env INSTANCE_TYPES_TO_ENABLE="${INSTANCE_TYPES_TO_ENABLE}" \
      ${FLAGS} \
      -p 22000:22000 \
      -p 21000:21000 \
      -p 20000:20000 \
      -v ${HOST_DOCKER_HOST}:/run/docker.sock \
      -v ${HOST_STORAGE_PATH}:${HOST_STORAGE_PATH} \
      --name elastic-cloud-enterprise-installer \
      --rm -i ${DOCKER_TTY} ${DOCKER_REGISTRY}/${ECE_DOCKER_REPOSITORY}/elastic-cloud-enterprise:${CLOUD_ENTERPRISE_VERSION} elastic-cloud-enterprise-installer
}

pullElasticCloudEnterpriseImage() {
  printf "%s\n" "Pulling ${DOCKER_REGISTRY}/${ECE_DOCKER_REPOSITORY}/elastic-cloud-enterprise:${CLOUD_ENTERPRISE_VERSION} image."
  dockerCmdViaSocket pull ${DOCKER_REGISTRY}/${ECE_DOCKER_REPOSITORY}/elastic-cloud-enterprise:${CLOUD_ENTERPRISE_VERSION}
}

defineHostIp() {
  local reason=""
  if [ -z ${HOST_IP} ]; then
    # first check that 'ip' tool exists
    if type 'ip' &> /dev/null ; then
      # 'ip' tool exists so lets attempt to get the interface to the default gateway.
      DEVICE=$(ip route show default | awk '/default/ {print $5}')
      if [ ! -z ${DEVICE} ]; then
        # now lets use 'ip' tool to get the ip of the network interface as the default HOST_IP
        HOST_IP=$(ip -4 addr show ${DEVICE}| grep -Po 'inet \K[\d.]+')
      else
        reason=" (the default gateway was not found)"
      fi
    else
      reason=" ('ip' tool can't be found)"
    fi
  fi
  if [ -z ${HOST_IP} ]; then
     # 'ip' tool doesn't exist so error out as we need --host-ip flag
     printf "${RED}%s${NC}\n" "Can't determine a default HOST_IP$reason. Please supply '--host-ip' with the appropriate ip address."
     exit $GENERAL_ERROR_EXIT_CODE
  fi
}

parseStackVersionArguments() {
  SOURCE_CONTAINER_NAME="frc-runners-runner"
  USER="admin"
  PASS=""
  VERSION=""
  SECRETS_RELATIVE_PATH="/bootstrap-state/bootstrap-secrets.json"

  while [ "$1" != "" ]; do
    case $1 in
        --host-docker-host )          setArgumentWithFilter HOST_DOCKER_HOST $1 $2
                                      shift
                                      ;;
        --user )                      setArgument USER $1 $2
                                      shift
                                      ;;
        --secrets )                   setArgument BOOTSTRAP_SECRETS $1 $2
                                      BOOTSTRAP_SECRETS=$(cd "$(dirname "$BOOTSTRAP_SECRETS")"; pwd)/$(basename "$BOOTSTRAP_SECRETS")
                                      shift
                                      ;;
        --pass )                      setArgument PASS $1 $2
                                      shift
                                      ;;
        --version )                   setArgument VERSION $1 $2
                                      shift
                                      ;;

        --podman )                    CONTAINER_ENGINE=podman
                                      ;;
        --help|help )     echo "================================================================================"
                          echo "Download and add a new Elastic Stack version from upstream."
                          echo "The script must be run on a host that is a part of an Elastic Cloud Enterprise"
                          echo "installation."
                          echo ""
                          echo "${0##*/} add-stack-version"
                          echo "[--host-docker-host HOST_DOCKER_HOST] [--secrets PATH_TO_SECRETS_FILE]"
                          echo "[--user USER_NAME] [--pass PASSWORD] [--version A.B.C] [--podman] [[--]help]"
                          echo ""
                          echo "Arguments:"
                          echo ""
                          echo "--host-docker-host   Set the docker's docker-host location"
                          echo "                     Defaults to /var/run/docker.sock"
                          echo ""
                          echo "--secrets            Specifies a path to a file with secrets."
                          echo "                     Defaults to '$HOST_STORAGE_PATH$SECRETS_RELATIVE_PATH'"
                          echo ""
                          echo "--user               The user to auth as to the adminconsole"
                          echo "                     Defaults to 'admin'"
                          echo ""
                          echo "--pass               Password to auth as to the adminconsole. If it is"
                          echo "                     not specified, it is attempted sourced from the secrets file"
                          echo ""
                          echo "--version            The version to add"
                          echo ""
                          echo "--podman             Use podman as container engine instead of docker"
                          echo ""
                          echo "Example:"
                          echo "${0##*/} add-stack-version --version 5.4.0"
                          echo ""
                          exit 0
                          ;;
       *)  echo -e "${RED}Unknown argument '$1'${NC}"
           exit $INVALID_ARGUMENT_EXIT_CODE
           ;;
    esac
    shift
  done

  DEFAULT_BOOTSTRAP_SECRETS="$HOST_STORAGE_PATH$SECRETS_RELATIVE_PATH"

  if [[ -z "$BOOTSTRAP_SECRETS" ]]; then
      # if neither bootstrap secrets file nor root password are specified, try find secrets file by the default path
      if [[ -e "$DEFAULT_BOOTSTRAP_SECRETS" ]] && [[ -z "$PASS" ]]; then
        echo -e "${YELLOW}A bootstrap secrets file was found using the default path${NC}"
        BOOTSTRAP_SECRETS=$DEFAULT_BOOTSTRAP_SECRETS
      fi
  else
      if [[ ! -e "$BOOTSTRAP_SECRETS" ]]; then
        echo -e "${RED}A bootstrap secrets file was not found using path '$BOOTSTRAP_SECRETS'${NC}"
        exit $INVALID_ARGUMENT_EXIT_CODE
      fi

      if test ! -r ${BOOTSTRAP_SECRETS}; then
        echo -e "${RED}Secrets file '${BOOTSTRAP_SECRETS}' doesn't have read permissions for the current user.${NC}"
        exit $INVALID_ARGUMENT_EXIT_CODE
      fi

      PASS=""
  fi

  if [[ -z "$PASS" ]] && [[ -z "$BOOTSTRAP_SECRETS" ]]; then
      echo -e "${RED}No password specified, and could not source a secrets file.${NC}"
      exit $INVALID_ARGUMENT_EXIT_CODE
  fi
}

# Perform pre-condition checks on the host before starting the installation
verifyHostPreconditions() {
  # Check if we can connect to the docker socket
  validateDockerSocket

  # Check UserID spaces and group membership
  validateRunningUser

  # Check if firewalld is active
  verifyFirewalldPrecondition
}

# Validate that the firewalld service is off
# If it is active then there is an issue when it tries to update the IPTables
verifyFirewalldPrecondition(){
  if hash systemctl 2>/dev/null; then
    local is_active=$(systemctl is-active firewalld)
    if [[ "$is_active" == "active" ]]; then
      HOST_PREREQ_FAILED=true
      echo -e "${RED}The firewalld service is not compatible with Docker" \
        "and interferes with the installation of ECE." \
        "To resolve this issue, disable firewalld and reinstall ECE.${NC}"
      if [[ "${FORCE_INSTALL}" == "false" ]]; then
        exit $PRECONDITION_NOT_MET_EXIT_CODE;
      fi
    fi
  fi
}

# Quickly detect if the docker socket location exists or not
validateDockerSocket(){
  if [ ! -S "${HOST_DOCKER_HOST}" ]; then
    echo -e "${RED}ECE could not verify the Docker socket (${HOST_DOCKER_HOST})." \
      "\nTo resolve the issue, verify that the Docker daemon is running on this host and" \
      "that you are using the correct Docker socket to connect to the daemon.${NC}"
    exit $PRECONDITION_NOT_MET_EXIT_CODE;
  fi
}

# Get host kernel paratmeters that ECE requires to validate
# Only get the specific kernel parameter so to limit the amount of data being passed through
# sysctl might be on the PATH, it might be in /sbin (Ubuntu), or it might be in /usr/sbin (CentOS)
getHostKernelParameters(){
  # Piping error to /dev/null to keep internal errors off of the user's terminal
  if [ -n "$(which sysctl 2>/dev/null)" ]; then
    HOST_KERNEL_PARAMETERS=$(sysctl net/ipv4/ip_local_port_range)
  elif [ -e "/sbin/sysctl" ]; then
    HOST_KERNEL_PARAMETERS=$(/sbin/sysctl net/ipv4/ip_local_port_range)
  elif [ -e "/usr/sbin/sysctl" ]; then
    HOST_KERNEL_PARAMETERS=$(/usr/sbin/sysctl net/ipv4/ip_local_port_range)
  else
    HOST_KERNEL_PARAMETERS=""
    echo -e "${YELLOW}The installation process was not able to check the host kernel parameters, which might affect other prerequisite checks." \
    "\nTo resolve this issue, make sure sysctl is on the PATH or in /sbin or /usr/sbin." \
    "\nContinuing the installation process...${NC}"
  fi
}

main() {
  # When we use the default value from the DOCKER_HOST envrionment variable then
  # it contains the unix:// prefix that we should omit because then when we
  # bind-mount it to the docker will result in invalid file
  setArgumentWithFilter HOST_DOCKER_HOST HOST_DOCKER_HOST "${HOST_DOCKER_HOST}"

  if [ $COMMAND == "install" ]; then
    parseInstallArguments "$@"
    verifyHostPreconditions
    createAndValidateHostStoragePath
    defineHostIp
    if [ ${OVERWRITE_EXISTING_IMAGE} == true ]; then
        pullElasticCloudEnterpriseImage
    fi
    getHostKernelParameters
    runBootstrapInitiatorContainer
  elif [ $COMMAND == "reset-adminconsole-password" ]; then
    parseResetAdminconsolePasswordArguments "$@"
    resetAdminconsolePassword
  elif [ $COMMAND == "add-stack-version" ]; then
    parseStackVersionArguments "$@"
    addStackVersion
  elif [ $COMMAND == "upgrade" ]; then
    parseUpgradeArguments "$@"
    if [ ${OVERWRITE_EXISTING_IMAGE} == true ]; then
        pullElasticCloudEnterpriseImage
    fi
    runUpgradeContainer
  fi

}

# Main function
main "$@"
