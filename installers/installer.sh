#!/usr/bin/env bash

function __check_os_version() {
    __log_debug "Checking OS compatability"
    export OS_VERSION="UNKNOWN"
    SUPPORTED_VERSIONS=("UNKNOWN")
    os=$1
    if [[ "$os" == "CENTOS" ]]; then
        OS_VERSION=$(awk '/^VERSION_ID=/{print $1}' /etc/os-release | awk -F"=" '{print $2}' | sed -e 's/^"//' -e 's/"//' | cut -c1-1)
        SUPPORTED_VERSIONS=("${CENTOS_OS_SUPPORTED_VERSIONS[@]}")
    elif [[ "$os" == "DEBIAN" ]]; then
        OS_VERSION=$(awk 'NR==1{print $3}' /etc/issue)
        SUPPORTED_VERSIONS=("${DEBIAN_OS_SUPPORTED_VERSIONS[@]}")
    elif [[ "$os" == "RHEL" ]]; then
        OS_VERSION=$(awk '/^VERSION_ID=/{print $1}' /etc/os-release | awk -F"=" '{print $2}' | sed -e 's/^"//' -e 's/"//' | cut -c1-1)
        SUPPORTED_VERSIONS=("${RHEL_OS_SUPPORTED_VERSIONS[@]}")
    else
        OS_VERSION=$(awk 'NR==1{print $2}' /etc/issue | cut -c-5)
        SUPPORTED_VERSIONS=("${UBUNTU_OS_SUPPORTED_VERSIONS[@]}")
    fi
    __log_debug "OS version is: '${OS_VERSION}'"
    __log_debug "Supported Versions are: ${SUPPORTED_VERSIONS[*]}"
    supported=$(__elementIn "${OS_VERSION}" "${SUPPORTED_VERSIONS[@]}")
    __log_debug "Is supported: $supported"
    if [[ "$supported" == "1" ]]; then
        __log_error "This version of ${os} is not supported by Couchbase Server CCs."
        exit 1
    fi
}

function __centos_prerequisites() {
    local sync_gateway=$1
    yum update -q -y
    yum install epel-release jq net-tools python2 wget -q -y
    python2 -m pip -q install httplib2
}

function __ubuntu_prerequisites() {
    local sync_gateway=$1
    __log_debug "Updating package repositories"
    until apt-get update > /dev/null; do
        __log_error "Error performing package repository update"
        sleep 2
    done
    # shellcheck disable=SC2034
    DEBIAN_FRONTEND=noninteractive
    __log_debug "Installing Prequisites"
    until apt-get install --assume-yes apt-utils dialog python-httplib2 jq net-tools wget lsb-release  -qq > /dev/null; do
        __log_error "Error during pre-requisite installation"
        sleep 2
    done
    __log_debug "Prequisitie Installation complete"
}

function __rhel_prerequisites() {
    local sync_gateway=$1
    yum update -q -y
    if [[ "$OS_VERSION" == 8* ]]; then
        yum install https://dl.fedoraproject.org/pub/epel/epel-release-latest-8.noarch.rpm -q -y
    else
        yum install epel-release -q -y
    fi
    yum install jq net-tools python2 wget -q -y
    python2 -m pip -q install httplib2
}

function __debian_prerequisites() {
    __ubuntu_prerequisites "$1"
}

function __amazon_prerequisites() {
    local sync_gateway=$1
    yum update -q -y
    amazon-linux-extras install epel
    yum install jq net-tools python2 python-pip wget -q -y
    python2 -m pip -q install httplib2
}

function __get_gcp_metadata_value() {
    wget -O - \
         --header="Metadata-Flavor:Google" \
         -q \
         --retry-connrefused \
         --waitretry=1 \
         --read-timeout=10 \
         --timeout=10 \
         -t 5 \
         "http://metadata/computeMetadata/v1/$1"
}

function __get_gcp_attribute_value() {
    __get_gcp_metadata_value "instance/attributes/$1"
}

#These values are for GCP
export ACCESS_TOKEN=""
export PROJECT_ID=""
export EXTERNAL_IP=""
export CONFIG=""
export EXTERNAL_IP_VAR_PATH=""
export SUCCESS_STATUS_PATH=""
export FAILURE_STATUS_PATH=""
export NODE_PRIVATE_DNS=""
export EXTERNAL_IP_PAYLOAD=""

function __install_prerequisites() {
    local os=$1
    local sync_gateway=$2
    local env=$3
    __check_os_version "$os"
    __log_debug "Prequisites Installation"
    if [[ "$os" == "CENTOS" ]]; then
        __centos_prerequisites "$sync_gateway"
    elif [[ "$os" == "DEBIAN" ]]; then
        __debian_prerequisites "$sync_gateway"
    elif [[ "$os" == "RHEL" ]]; then
        __rhel_prerequisites "$sync_gateway"
    elif [[ "$os" == "AMAZON" ]]; then
        __amazon_prerequisites "$sync_gateway"
    else
        __ubuntu_prerequisites "$sync_gateway"
    fi

    #There are some "startup" functions that need run for GCP script
    if [[ "$env" == "GCP" ]]; then
        __log_debug "Running GCP Prequisites"
        ACCESS_TOKEN=$(__get_gcp_metadata_value "instance/service-accounts/default/token" | jq -r '.access_token')
        __log_debug "GCP Access Token:  $ACCESS_TOKEN"
        PROJECT_ID=$(__get_gcp_metadata_value "project/project-id")
        __log_debug "GCP Project Id: $PROJECT_ID"
        EXTERNAL_IP=$(__get_gcp_metadata_value "instance/network-interfaces/0/access-configs/0/external-ip")
        __log_debug "GCP External IP:  $EXTERNAL_IP"
        CONFIG=$(__get_gcp_attribute_value "runtime-config-name")
        __log_debug "GCP Config: $CONFIG"
        EXTERNAL_IP_VAR_PATH=$(__get_gcp_attribute_value "external-ip-variable-path")
        __log_debug "GCP External Ip Var Path: $EXTERNAL_IP_VAR_PATH"
        SUCCESS_STATUS_PATH="$(__get_gcp_attribute_value "status-success-base-path")/$(hostname)"
        __log_debug "GCP Success Status Path: $SUCCESS_STATUS_PATH"
        FAILURE_STATUS_PATH="$(__get_gcp_attribute_value "status-failure-base-path")/$(hostname)"
        __log_debug "GCP Failure Status Path: $FAILURE_STATUS_PATH"
        NODE_PRIVATE_DNS=$(__get_gcp_metadata_value "instance/hostname")
        __log_debug "GCP Node Private DNS: $NODE_PRIVATE_DNS"
        EXTERNAL_IP_PAYLOAD="$(printf '{"name": "%s", "text": "%s"}' \
            "projects/${PROJECT_ID}/configs/${CONFIG}/variables/${EXTERNAL_IP_VAR_PATH}" \
            "${EXTERNAL_IP}")"

        wget -O - \
             -q \
             --retry-connrefused \
             --waitretry=1 \
             --read-timeout=10 \
             --timeout=10 \
             -t 5 \
             --header="Authorization: Bearer ${ACCESS_TOKEN}" \
             --header "Content-Type: application/json" \
             --header "X-GFE-SSL: yes" \
             --method=PUT \
             --body-data="$EXTERNAL_IP_PAYLOAD" \
             "https://runtimeconfig.googleapis.com/v1beta1/projects/${PROJECT_ID}/configs/variables/${EXTERNAL_IP_VAR_PATH}"
    fi
    __log_debug "Prequisites Complete"
}


# https://docs.couchbase.com/server/current/install/thp-disable.html
turnOffTransparentHugepages ()
{
    local os=$1
    __log_debug "Disabling Transparent Hugepages"
    echo "#!/bin/bash
### BEGIN INIT INFO
# Provides:          disable-thp
# Required-Start:    \$local_fs
# Required-Stop:
# X-Start-Before:    couchbase-server
# Default-Start:     2 3 4 5
# Default-Stop:      0 1 6
# Short-Description: Disable THP
# Description:       Disables transparent huge pages (THP) on boot, to improve
#                    Couchbase performance.
### END INIT INFO

case \$1 in
  start)
    if [ -d /sys/kernel/mm/transparent_hugepage ]; then
      thp_path=/sys/kernel/mm/transparent_hugepage
    elif [ -d /sys/kernel/mm/redhat_transparent_hugepage ]; then
      thp_path=/sys/kernel/mm/redhat_transparent_hugepage
    else
      return 0
    fi

    echo 'never' > \${thp_path}/enabled
    echo 'never' > \${thp_path}/defrag

    re='^[0-1]+$'
    if [[ \$(cat \${thp_path}/khugepaged/defrag) =~ \$re ]]
    then
      # RHEL 7
      echo 0  > \${thp_path}/khugepaged/defrag
    else
      # RHEL 6
      echo 'no' > \${thp_path}/khugepaged/defrag
    fi

    unset re
    unset thp_path
    ;;
esac
    " > /etc/init.d/disable-thp
    chmod 755 /etc/init.d/disable-thp
    if [[ "$os" == "CENTOS"  || "$os" == "RHEL" || "$os" == "AMAZON" ]]; then
        chkconfig --add disable-thp
    elif [[ "$os" == "DEBIAN" || "$os" == "UBUNTU" ]]; then
        update-rc.d disable-thp defaults
    fi
    service disable-thp start

    __log_debug "Transparent Hugepages have been disabled."
}

adjustTCPKeepalive ()
{
# Azure public IPs have some odd keep alive behaviour
# A summary is available here https://docs.mongodb.org/ecosystem/platforms/windows-azure/
    if [[ "$2" == "AZURE" ]] && [[ "$1" == "UBUNTU" || "$1" == "DEBIAN" ]] ; then
        __log_debug "Setting TCP keepalive..."
        sysctl -w net.ipv4.tcp_keepalive_time=120 -q

        __log_debug "Setting TCP keepalive permanently..."
        echo "net.ipv4.tcp_keepalive_time = 120
        " >> /etc/sysctl.conf
        __log_debug "TCP keepalive setting changed."
    fi

}

formatDataDisk ()
{
    local os=$1
    local env=$2
    local sync_gateway=$3
    if [[ "$env" == "AWS" && "$sync_gateway" -eq "0" ]]; then
        __log_debug "AWS: Formatting data disk"
        DEVICE=/dev/sdk
        MOUNTPOINT=/mnt/datadisk
        mkfs -t ext4 ${DEVICE}
        LINE="${DEVICE}\t${MOUNTPOINT}\text4\tdefaults,nofail\t0\t2"
        echo -e ${LINE} >> /etc/fstab
        mkdir $MOUNTPOINT
        mount -a
        chown couchbase $MOUNTPOINT
        chgrp couchbase $MOUNTPOINT
    fi

    if [[ "$env" == "AZURE" && "$sync_gateway" -eq "0" ]]; then
        # This script formats and mounts the drive on lun0 as /datadisk
        __log_debug "AZURE: Formatting data disk"

        DISK="/dev/disk/azure/scsi1/lun0"
        PARTITION="/dev/disk/azure/scsi1/lun0-part1"
        MOUNTPOINT="/datadisk"

        __log_debug "Partitioning the disk."
        echo "n
        p
        1


        t
        83
        w"| fdisk ${DISK}

        __log_debug "Waiting for the symbolic link to be created..."
        udevadm settle --exit-if-exists=$PARTITION

        __log_debug "Creating the filesystem."
        mkfs -j -t ext4 ${PARTITION}

        __log_debug "Updating fstab"
        LINE="${PARTITION}\t${MOUNTPOINT}\text4\tnoatime,nodiratime,nodev,noexec,nosuid\t1\t2"
        echo -e ${LINE} >> /etc/fstab

        __log_debug "Mounting the disk"
        mkdir -p $MOUNTPOINT
        mount -a

        __log_debug "Changing permissions"
        chown couchbase $MOUNTPOINT
        chgrp couchbase $MOUNTPOINT
    fi
}

setSwappiness()
{
    KERNEL_VERSION=$(uname -r)
    RET=$(__compareVersions "$KERNEL_VERSION" "3.5.0")
    SWAPPINESS=0
    if [[ "$RET" == "1" ]]; then
        SWAPPINESS=1
    fi
    __log_debug "Setting Swappiness to Zero"
    echo "
    # Required for Couchbase
    vm.swappiness = ${SWAPPINESS}
    " >> /etc/sysctl.conf

    sysctl vm.swappiness=${SWAPPINESS} -q

    __log_debug "Swappiness set to Zero"
}

# These are not exactly necessary.. But are here in case we need custom environment settings per OS
function __centos_environment() {
    __log_debug "Configuring CENTOS Specific Environment Settings"
}

function __debian_environment() {
    __log_debug "Configuring DEBIAN Specific Environment Settings"
}

function __ubuntu_environment() {
    __log_debug "Configuring UBUNTU Specific Environment Settings"
}

function __rhel_environment() {
    __log_debug "Configuring RHEL Specific Environment Settings"
}

function __amazon_environment() {
    __log_debug "Configuring Amazon Linux Specific Environment Settings"
}

function __configure_environment() {
    echo "Setting up Environment"
    local env=$1
    local os=$2
    local sync_gateway=$3
    __log_debug "Setting up for environment: ${env}"
    turnOffTransparentHugepages "$os" "$env" "$sync_gateway"
    setSwappiness "$os" "$env" "$sync_gateway"
    adjustTCPKeepalive "$os" "$env" "$sync_gateway"
    formatDataDisk "$os" "$env" "$sync_gateway"
    if [[ "$os" == "CENTOS" ]]; then
        __centos_environment "$env" "$sync_gateway"
    elif [[ "$os" == "DEBIAN" ]]; then
        __debian_environment "$env" "$sync_gateway"
    elif [[ "$os" == "RHEL" ]]; then
        __rhel_environment "$env" "$sync_gateway"
    elif [[ "$os" == "AMAZON" ]]; then
        __amazon_environment "$env" "$sync_gateway"
    else
        __ubuntu_environment "$env" "$sync_gateway"
    fi
}

function __install_syncgateway_centos() {
    local version=$1
    local tmp=$2
    __log_info "Installing Couchbase Sync Gateway Enterprise Edition v${version}"
    __log_debug "Downloading installer to: ${tmp}"
    wget -O "${tmp}/couchbase-sync-gateway-enterprise_${version}_x86_64.rpm" "https://packages.couchbase.com/releases/couchbase-sync-gateway/${version}/couchbase-sync-gateway-enterprise_${version}_x86_64.rpm" --quiet
    __log_debug "Download complete. Beginning Unpacking"
    if ! rpm -i "${tmp}/couchbase-sync-gateway-enterprise_${version}_x86_64.rpm" > /dev/null; then
        __log_error "Error while installing ${tmp}/couchbase-sync-gateway-enterprise_${version}_x86_64.rpm"
        exit 1
    fi

}
function __install_syncgateway_rhel() {
    __install_syncgateway_centos "$1" "$2"
}
function __install_syncgateway_amazon() {
    __install_syncgateway_centos "$1" "$2"
}

function __install_syncgateway_ubuntu() {
    #https://packages.couchbase.com/releases/7.0.0-beta/couchbase-server-community_7.0.0-beta-ubuntu18.04_amd64.deb
    local version=$1
    local tmp=$2
    __log_info "Installing Couchbase Sync Gateway community Edition v${version}"
    __log_debug "Downloading installer to: ${tmp}"
    wget -O "${tmp}/couchbase-sync-gateway-community_${version}_x86_64.deb" "https://packages.couchbase.com/releases/couchbase-sync-gateway/${version}/couchbase-sync-gateway-community_${version}_x86_64.deb" --quiet
    __log_debug "Download complete. Beginning Unpacking"
    if ! dpkg -i "${tmp}/couchbase-sync-gateway-community_${version}_x86_64.deb" > /dev/null ; then
        __log_error "Error while installing ${tmp}/couchbase-sync-gateway-community_${version}_x86_64.deb"
        exit 1
    fi
}
function __install_syncgateway_debian() {
    __install_syncgateway_ubuntu "$1" "$2"
}
function __install_syncgateway() {
    local version=$1
    local tmp=$2
    local os=$3
    __log_debug "Installing Sync Gateway"
    __log_debug "Setting up sync gateway user"
    useradd sync_gateway
    __log_debug "Creating sync_gateway home directory"
    mkdir -p /home/sync_gateway/
    chown sync_gateway:sync_gateway /home/sync_gateway
    if [[ "$os" == "CENTOS" ]]; then
        version=$(__findClosestVersion "$1" "${CENTOS_SUPPORTED_SYNC_GATEWAY_VERSIONS[@]}")
        __install_syncgateway_centos "$version" "$tmp"
    elif [[ "$os" == "DEBIAN" ]]; then
        version=$(__findClosestVersion "$1" "${DEBIAN_SUPPORTED_SYNC_GATEWAY_VERSIONS[@]}")
        __install_syncgateway_debian "$version" "$tmp"
    elif [[ "$os" == "RHEL" ]]; then
        version=$(__findClosestVersion "$1" "${RHEL_SUPPORTED_SYNC_GATEWAY_VERSIONS[@]}")
        __install_syncgateway_rhel "$version" "$tmp"
    elif [[ "$os" == "AMAZON" ]]; then
        version=$(__findClosestVersion "$1" "${AMAZON_LINUX_SUPPORTED_SYNC_GATEWAY_VERSIONS[@]}")
        __install_syncgateway_amazon "$version" "$tmp"        
    else
        version=$(__findClosestVersion "$1" "${UBUNTU_SUPPORTED_SYNC_GATEWAY_VERSIONS[@]}")
        __install_syncgateway_ubuntu "$version" "$tmp"
    fi

    __log_info "Installation Complete. Configuring Couchbase Sync Gateway"

    file="/home/sync_gateway/sync_gateway.json"
    echo '
    {
    "interface": "0.0.0.0:4984",
    "adminInterface": "0.0.0.0:4985",
    "log": ["*"]
    }
    ' > ${file}
    chmod 755 ${file}
    chown sync_gateway ${file}
    chgrp sync_gateway ${file}

    # Need to restart sync gateway service to load the changes
    if [[ "$os" == "CENTOS" ]]; then
        service sync_gateway stop
        service sync_gateway start
    else
        systemctl stop sync_gateway
        systemctl start sync_gateway
    fi
}

function __install_couchbase_centos() {
    local version=$1
    local tmp=$2
    __log_info "Installing Couchbase Server v${version}..."
    __log_debug "Downloading installer to: ${tmp}"
    wget -O "${tmp}/couchbase-release-1.0-x86_64.rpm" https://packages.couchbase.com/releases/couchbase-release/couchbase-release-1.0-x86_64.rpm -q
    __log_debug "Download Complete.  Beginning Unpacking"
    rpm -i "${tmp}/couchbase-release-1.0-x86_64.rpm"
    __log_debug "Unpacking complete.  Beginning Installation"
    yum install "couchbase-server-${version}" -y -q
}

function __install_couchbase_rhel() {
    __install_couchbase_centos "$1" "$2"
}

function __install_couchbase_amazon() {
    __install_couchbase_centos "$1" "$2"
}

function __install_couchbase_ubuntu() { 
    local version=$1
    local tmp=$2
    __log_info "Installing Couchbase Server v${version}..."
    __log_debug "Downloading installer to: ${tmp}"
    wget -O "${tmp}/couchbase-server-community_${version}-ubuntu${OS_VERSION}_amd64.deb" "https://packages.couchbase.com/releases/${version}/couchbase-server-community_${version}-ubuntu18.04_amd64.deb" -q
    __log_debug "Download Complete.  Beginning Unpacking"
    until dpkg -i "${tmp}/couchbase-server-community_${version}-ubuntu${OS_VERSION}_amd64.deb" > /dev/null; do
        __log_error "Error while installing ${tmp}/couchbase-server-community_${version}-ubuntu${OS_VERSION}_amd64.deb"
        sleep 1
    done
    __log_debug "Unpacking complete.  Beginning Installation"
    until apt-get update -qq > /dev/null; do
        __log_error "Error updating package repositories"
        sleep 1
    done
    until apt-get -y install couchbase-server-community -qq > /dev/null; do
        __log_error "Error while installing ${tmp}/couchbase-server-community_${version}-ubuntu${OS_VERSION}_amd64.deb"
        sleep 1
    done
}

function __install_couchbase_debian() {
    local version=$1
    local tmp=$2
    __log_info "Installing Couchbase Server v${version}..."
    __log_debug "Downloading installer to: ${tmp}"
    wget -O "${tmp}/couchbase-server-enterprise_${version}-debian${OS_VERSION}_amd64.deb" "http://packages.couchbase.com/releases/${version}/couchbase-server-enterprise_${version}-debian${OS_VERSION}_amd64.deb" -q
    __log_debug "Download Complete.  Beginning Unpacking"
    until dpkg -i "${tmp}/couchbase-server-enterprise_${version}-debian${OS_VERSION}_amd64.deb" > /dev/null; do
        __log_error "Error while installing ${tmp}/couchbase-server-enterprise_${version}-debian${OS_VERSION}_amd64.deb"
        sleep 1
    done
    __log_debug "Unpacking complete.  Beginning Installation"
    until apt-get update -qq > /dev/null; do
        __log_error "Error updating package repositories"
        sleep 1
    done
    until apt-get -y install couchbase-server -qq > /dev/null; do
        __log_error "Error while installing ${tmp}/couchbase-server-enterprise_${version}-debian${OS_VERSION}_amd64.deb"
        sleep 1
    done
}
function __install_couchbase() {
    local version=$1
    local tmp=$2
    local os=$3
    local sync_gateway=$4
    if [[ "$sync_gateway" -eq "1" ]]; then
        __install_syncgateway "$version" "$tmp" "$os"
        return 0
    fi
    echo "Installing Couchbase"
        if [[ "$os" == "CENTOS" ]]; then
        version=$(__findClosestVersion "$1" "${CENTOS_SUPPORTED_VERSIONS[@]}")
        __install_couchbase_centos "$version" "$tmp"
    elif [[ "$os" == "DEBIAN" ]]; then
        if [[ "$OS_VERSION" == "8" ]]; then
            version=$(__findClosestVersion "$1" "${DEBIAN_8_SUPPORTED_VERSIONS[@]}")
        fi
        if [[ "$OS_VERSION" == "9" ]]; then
            version=$(__findClosestVersion "$1" "${DEBIAN_9_SUPPORTED_VERSIONS[@]}")
        fi
        if [[ "$OS_VERSION" == "10" ]]; then
            version=$(__findClosestVersion "$1" "${DEBIAN_10_SUPPORTED_VERSIONS[@]}")
        fi
        __install_couchbase_debian "$version" "$tmp"
    elif [[ "$os" == "RHEL" ]]; then
        if [[ "$OS_VERSION" == "8" ]]; then
            version=$(__findClosestVersion "$1" "${RHEL_8_SUPPORTED_VERSIONS[@]}")
        fi
        if [[ "$OS_VERSION" == "7" ]]; then
            version=$(__findClosestVersion "$1" "${RHEL_7_SUPPORTED_VERSIONS[@]}")
        fi
        if [[ "$OS_VERSION" == "6" ]]; then
            version=$(__findClosestVersion "$1" "${RHEL_6_SUPPORTED_VERSIONS[@]}")
        fi
        __install_couchbase_rhel "$version" "$tmp"
    elif [[ "$os" == "AMAZON" ]]; then
        version=$(__findClosestVersion "$1" "${AMAZON_LINUX_SUPPORTED_VERSIONS[@]}")
        __install_couchbase_amazon "$version" "$tmp"
    else
        if [[ "$OS_VERSION" == "14.04" ]]; then
            version=$(__findClosestVersion "$1" "${UBUNTU_14_SUPPORTED_VERSIONS[@]}")
        fi
        if [[ "$OS_VERSION" == "16.04" ]]; then
            version=$(__findClosestVersion "$1" "${UBUNTU_16_SUPPORTED_VERSIONS[@]}")
        fi
        if [[ "$OS_VERSION" == "18.04" ]]; then
            version=$(__findClosestVersion "$1" "${UBUNTU_18_SUPPORTED_VERSIONS[@]}")
        fi
        if [[ "$OS_VERSION" == "20.04" ]]; then
            version=$(__findClosestVersion "$1" "${UBUNTU_20_SUPPORTED_VERSIONS[@]}")
        fi
        __install_couchbase_ubuntu "$version" "$tmp"
    fi

    export CLI_INSTALL_LOCATION="/opt/couchbase/bin"

}
# This is a method to perform any final actions after the cluster has been created and/or joined
# Precipitated because GCP requires us to send a "Success" after we're done doing our work
function __post_install_finalization() {
    __log_debug "Beginning Post Install Finalization for environment $1"
    local env=$1

    if [[ "$env" == "GCP" ]]; then
        ACCESS_TOKEN=$(__get_gcp_metadata_value "instance/service-accounts/default/token" | jq -r '.access_token')
        __log_debug "GCP Access Token:  $ACCESS_TOKEN"
        PROJECT_ID=$(__get_gcp_metadata_value "project/project-id")
        __log_debug "GCP Project Id: $PROJECT_ID"
        CONFIG=$(__get_gcp_attribute_value "runtime-config-name")
        __log_debug "GCP Config: $CONFIG"
        SUCCESS_STATUS_PATH="$(__get_gcp_attribute_value "status-success-base-path")/$(hostname)"
        __log_debug "GCP Success Status Path: $SUCCESS_STATUS_PATH"
        FAILURE_STATUS_PATH="$(__get_gcp_attribute_value "status-failure-base-path")/$(hostname)"
        __log_debug "GCP Failure Status Path: $FAILURE_STATUS_PATH"
        host=$(hostname)
        SUCCESS_PAYLOAD="$(printf '{"name": "%s", "text": "%s"}' \
        "projects/${PROJECT_ID}/configs/${CONFIG}/variables/${SUCCESS_STATUS_PATH}/${host}" \
        "success")"

        __log_debug "Sending success notification for startup waiter on GCP"

        # Notify waiter
        wget -O - \
            --retry-connrefused \
            --waitretry=1 \
            --read-timeout=10 \
            --timeout=10 \
            -t 5 \
            --body-data="${SUCCESS_PAYLOAD}" \
            --header="Authorization: Bearer ${ACCESS_TOKEN}" \
            --header "Content-Type: application/json" \
            --header "X-GFE-SSL: yes" \
            --method=POST \
            "https://runtimeconfig.googleapis.com/v1beta1/projects/${PROJECT_ID}/configs/${CONFIG}/variables"
    fi
}