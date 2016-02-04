#!/bin/bash

# @file ovf-sc.sh
#
# Project Clearwater - IMS in the Cloud
# Copyright (C) 2015  Metaswitch Networks Ltd
#
# This program is free software: you can redistribute it and/or modify it
# under the terms of the GNU General Public License as published by the
# Free Software Foundation, either version 3 of the License, or (at your
# option) any later version, along with the "Special Exception" for use of
# the program along with SSL, set forth below. This program is distributed
# in the hope that it will be useful, but WITHOUT ANY WARRANTY;
# without even the implied warranty of MERCHANTABILITY or FITNESS FOR
# A PARTICULAR PURPOSE.  See the GNU General Public License for more
# details. You should have received a copy of the GNU General Public
# License along with this program.  If not, see
# <http://www.gnu.org/licenses/>.
#
# The author can be reached by email at clearwater@metaswitch.com or by
# post at Metaswitch Networks Ltd, 100 Church St, Enfield EN2 6BQ, UK
#
# Special Exception
# Metaswitch Networks Ltd  grants you permission to copy, modify,
# propagate, and distribute a work formed by combining OpenSSL with The
# Software, or a work derivative of such a combination, even if such
# copying, modification, propagation, or distribution would otherwise
# violate the terms of the GPL. You must comply with the GPL in all
# respects for all of the code used other than OpenSSL.
# "OpenSSL" means OpenSSL toolkit software distributed by the OpenSSL
# Project and licensed under the OpenSSL Licenses, or a work based on such
# software and licensed under the OpenSSL Licenses.
# "OpenSSL Licenses" means the OpenSSL License and Original SSLeay License
# under which the OpenSSL Project distributes the OpenSSL toolkit software,
# as those licenses appear in the file LICENSE-OPENSSL.

# Pull in support functions
. /var/cc-ovf/bin/ovf-sc

# Turn off environment option to exit on non-zero status of sub-commands.
set +e

# Defaults to control whether to configure IPv4 and IPv6 configuration.
# Note: IPv6 can be overridden by later commands so '0' here does not guarantee
# that IPv6 will not be configured.
doIPv4=1
doIPv6=0

rm -f /var/log/ovf-sc.dhclient*.log
touch /var/log/ovf-sc.dhclient-4.log /var/log/ovf-sc.dhclient-6.log

# Send stdout/stderr to a log file as well as stdout/stderr respectively.
exec >  >( stdbuf -i0 -o0 -e0 tee /var/log/ovf-sc.log )
exec 2>&1

# Uncomment the following for more debugging output
#set -x

# Truncate the MOTD to avoid messages being left from previous runs.
: > /etc/motd

# Delay for a few seconds to let other upstart jobs to complete before we begin
sleep 2

# Print banner
printf "\n\
 * Starting Clearwater Core VA self configuration:\n\
"

# Function for parsing local configuration options and turning
# them into bash variables
getprops_from_ovfxml() {
/usr/bin/python - <<EOS
from xml.dom.minidom import parseString
ovfEnv = open("$1", "r").read()
dom = parseString(ovfEnv)
section = dom.getElementsByTagName("PropertySection")[0]
for property in section.getElementsByTagName("Property"):
   key = property.getAttribute("oe:key").replace('.','_')
   value = property.getAttribute("oe:value")
   print "{0}=\"{1}\"".format(key,value)
dom.unlink()
EOS
}

# Function to print out a command before executing it.
echo_and_run() { echo "$@" ; "$@" ; }

# Function for logging to syslog and stdout
log() {
    echo "   $*"
    logger "self-config:" "$*"
}

# Function to emit error/failure message and wait for user input.
# If the user doesn't response with 60 seconds, the node will
# be rebooted so as to try again in case the # problem is intermittent
# and we can recover automatically.
err() {
    (sleep 60; rm -f /boot/grub/grubenv; printf "\n\nRebooting..."; for i in {1..5}; do (sleep 1;sync;printf ".");done; reboot -f)&
    printf > /etc/motd "\
!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!\n\
!!                                                                           !!\n\
!!                          SELF-CONFIGURATION FAILED                        !!\n\
!!                                                                           !!\n\
!! %-73.73s !!\n\
!!                                                                           !!\n\
!! See /var/log/ovf-sc.log for more detailed information.                    !!\n\
!!                                                                           !!\n\
!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!\n" "$*"
    cat /etc/motd
    logger "self-config:" "$*"
    printf "Press <Enter> to troubleshoot..."
    read RESPONSE
    if [ ! -z $(jobs -p) ]; then
        kill -9 $(jobs -p)
    fi
    bash --norc --noprofile -i

    # Close stdout to flush to the log
    exec 1>&-
    exit 1
}

# Function to find the payload device
find_payload()
{
    for dev in $(ls -1 /sys/block/); do
        if [[ ! ${dev} =~ ^ram ]]; then
            if [[ ! ${dev} =~ ^loop ]]; then
                if [ -e /dev/${dev} ]; then
                    mkdir -p /tmp/$$
                    mount /dev/${dev} /tmp/$$ > /dev/null 2>&1
                    if [ -d /tmp/$$/payload ]; then
                        echo /dev/${dev}
                        umount /dev/${dev} > /dev/null 2>&1
                        rmdir /tmp/$$
                        break
                    fi
                    umount /dev/${dev} > /dev/null 2>&1
                    rmdir /tmp/$$
                fi
            fi
        fi
    done
}

# Check for VMWare tools
if [ ! -x /usr/bin/vmware-rpctool ]; then
    err "ERROR: VMware Tools are not installed. Halting ..."
fi

# Re-create the vApp properties xml file with the current settings.
rm -f /var/lib/cc-ovf/ovf.xml
rpctool_stderr=$(/usr/bin/vmware-rpctool 'info-get guestinfo.ovfEnv' >/var/lib/cc-ovf/ovf.xml 2> /var/lib/cc-ovf/$$; cat /var/lib/cc-ovf/$$; rm -f /var/lib/cc-ovf/$$)
if [ ! -s /var/lib/cc-ovf/ovf.xml ]; then
    # xml file is empty or doesn't exist.
    if [ "$rpctool_stderr" == "Failed sending message to VMware." ]; then
        log "INFO: Not running on VMWare"
    else
        if [ "$rpctool_stderr" == "No value found" ]; then
            log "INFO: Not running on vSphere"
        else
            err "ERROR: Cannot get VA parameters through VMware Tools. Halting ..."
        fi
    fi
fi

# Convert VA properties to bash variables
if [ -s /var/lib/cc-ovf/ovf.xml ]; then
    #Debugging
    printf "Debug info (ovf.xml):\n" 2>&1 | sed -e 's#^#   #'
    cat /var/lib/cc-ovf/ovf.xml 2>&1 | sed -e "s#^#     ${LINENO} #"

    # Parse the vApp properties into key=value lines in a new file.
    getprops_from_ovfxml /var/lib/cc-ovf/ovf.xml > /var/lib/cc-ovf/ovf.vars
#    cp -vp /var/lib/cc-ovf/ovf.vars /var/lib/cc-ovf
else
    # XML file is empty or doesn't exist so truncate the key=value file.
    rm -f /var/lib/cc-ovf/ovf.vars
    touch /var/lib/cc-ovf/ovf.vars
fi

cfg_dev=$(find_payload)

# Load environment variables from guestinfo or from '/ovf.env' on CD
if [ -s /var/lib/cc-ovf/ovf.vars ]; then
    # vApp variable file doesn't exist or is empty.
    vars_md5=$(md5sum -b /var/lib/cc-ovf/ovf.vars|awk '{print $1}')
    if [ -e /var/lib/cc-ovf/ovf.md5 ]; then
        if [ "$(cat /var/lib/cc-ovf/ovf.md5)" != "$vars_md5" ]; then
            err "ERROR: Changes to VMware (vApp) properties not allowed! Halting ..."
        fi
    fi
    printf "$vars_md5\n" > /var/lib/cc-ovf/ovf.md5

    printf "VA environment (per VMware/OpenStack properties):\n" 2>&1 | sed -e 's#^#   #'
    cat /var/lib/cc-ovf/ovf.vars 2>&1 | sed -e 's#^#     #'
    . /var/lib/cc-ovf/ovf.vars
    log "Applying VA customizations (per VMWare properties)..."
else
    if [ -e /dev/disk/by-label/config-2 ]; then
        mkdir -p /mnt/os.config
        echo mount /dev/disk/by-label/config-2 /mnt/os.config 2>&1 | sed -e 's#^#   #'
        mount /dev/disk/by-label/config-2 /mnt/os.config 2>&1 | sed -e 's#^#   #'

        rm -f /var/lib/cc-ovf/qcow.vars

        if [ -e /mnt/os.config/openstack/latest/user_data ]; then
            cp -fvp /mnt/os.config/openstack/latest/user_data /var/lib/cc-ovf/qcow.vars 2>&1 | sed -e 's#^#   #'
            chmod +w /var/lib/cc-ovf/qcow.vars
        fi

        if [ -e /mnt/os.config/openstack/latest/meta_data.json ]; then
            cat /mnt/os.config/openstack/latest/meta_data.json | python -mjson.tool | sed -n '/"meta":/,//{/"meta"/{p;n};/}/{q};p}'|grep -v "meta\":"|sed -e 's/^[[:space:]]*"//;s/":[[:space:]]*/=/;s/,$//' >> /var/lib/cc-ovf/qcow.vars
        fi

        echo umount /dev/disk/by-label/config-2 2>&1 | sed -e 's#^#   #'
        umount /dev/disk/by-label/config-2 2>&1 | sed -e 's#^#   #'

        vars_md5=$(md5sum -b /var/lib/cc-ovf/qcow.vars|awk '{print $1}')
        if [ -e /var/lib/cc-ovf/qcow.md5 ]; then
            if [ "$(cat /var/lib/cc-ovf/qcow.md5)" != "$vars_md5" ]; then
                err "ERROR: Changes to OpenStack config drive not allowed! Halting ..."
            fi
        fi
        printf "$vars_md5\n" > /var/lib/cc-ovf/qcow.md5

        if [ -s /var/lib/cc-ovf/qcow.vars ]; then
            printf "VA environment (per OpenStack config drive):\n" 2>&1 | sed -e 's#^#   #'
            cat /var/lib/cc-ovf/qcow.vars 2>&1 | sed -e 's#^#     #'
            . /var/lib/cc-ovf/qcow.vars
        fi
    else
        # Fetch QCOW2 variables from Metadata Service
        rm -f /var/lib/cc-ovf/qcow.vars
        wget -qO- --tries=1 --timeout=2 http://169.254.169.254/openstack/latest/meta_data.json > /tmp/qcow.wget
        if [ $? -eq 0 ]; then
            cat /tmp/qcow.wget | python -mjson.tool | sed -n '/"meta":/,//{/"meta"/{p;n};/}/{q};p}'|grep -v "meta\":"|sed -e 's/^[[:space:]]*"//;s/":[[:space:]]*/=/;s/,$//' >> /var/lib/cc-ovf/qcow.vars
            # Load OpenStack configuration variables
            vars_md5=$(md5sum -b /var/lib/cc-ovf/qcow.vars|awk '{print $1}')
            if [ -e /var/lib/cc-ovf/qcow.md5 ]; then
                if [ "$(cat /var/lib/cc-ovf/qcow.md5)" != "$vars_md5" ]; then
                   err "ERROR: Changes to OpenStack meta-data not allowed! Halting ..."
                fi
            fi
            printf "$vars_md5\n" > /var/lib/cc-ovf/qcow.md5

            if [ -s /var/lib/cc-ovf/qcow.vars ]; then
                printf "Appliance environment (per OpenStack meta-data service):\n" 2>&1 | sed -e 's#^#   #'
                cat /var/lib/cc-ovf/qcow.vars 2>&1 | sed -e 's#^#     #'
                . /var/lib/cc-ovf/qcow.vars
            fi
        fi
    fi
fi
if [[ ! -s /var/lib/cc-ovf/ovf.vars && ! -s /var/lib/cc-ovf/qcow.vars ]]; then
    if [ ! -z ${cfg_dev} ]; then
        log "INFO: No environment presented by the platform. Look for it on the CD..."
        mkdir -p /mnt/ovf.cfg
        mount ${cfg_dev} /mnt/ovf.cfg 2>&1 | sed -e 's#^#   #'
        if [ $? -ne 0 ]; then
            umount ${cfg_dev} 2>&1 | sed -e 's#^#   #'
            log "WARN: No CD..."
        else
            if [ ! -r /mnt/ovf.cfg/ovf.env ]; then
                # Unable to read from CD.
                umount ${cfg_dev} 2>&1 | sed -e 's#^#   #'
                log "WARN: No VA environment on the CD..."
                run_configurator=yes
            else
                # CD mounted and readable so add contents to environment.
                printf "VA environment (per cdrom/ovf.env):\n" 2>&1 | sed -e 's#^#   #'
                cat /mnt/ovf.cfg/ovf.env 2>&1 | sed -e 's#^#     #'
                . /mnt/ovf.cfg/ovf.env
                umount ${cfg_dev}
                log "Applying VA customizations (from CD)..."
            fi
        fi
    else
        log "WARN: No VA environment..."
        run_configurator=yes
    fi
fi

if [ "${run_configurator^^}" == "YES" ]; then
    if [ ! -e /var/lib/cc-ovf/configurator.vars ]; then
        if [ -x /var/cc-ovf/configurator/craft.bash ]; then
            log "WARN: No config.vars! Prompting the user..."
            printf "\
*******************************************************************************\n\
*                                                                             *\n\
* Clearwater Core's base configuration must be completed before continuing    *\n\
* the boot process. Use the following menus to complete this task and then    *\n\
* exit(0) to complete the process.                                            *\n\
*                                                                             *\n\
*******************************************************************************\n\
"
            /var/cc-ovf/configurator/craft.bash
            if [ ! -e /var/lib/cc-ovf/configurator.vars ]; then
                err "ERROR: Configurator failed!"
            fi
        fi
    fi
fi

if [ -e /var/lib/cc-ovf/configurator.vars ]; then
    log "INFO: Loading configurator vars..."
    cat /var/lib/cc-ovf/configurator.vars 2>&1 | sed -e 's#^#     #'
    . /var/lib/cc-ovf/configurator.vars
fi

#Setup protocol variables
if [ -z "${sip_protocol}${mgmt_protocol}" ]; then
    printf "ip_protocol=${ip_protocol}\n" 2>&1 | sed -e "s#^#     ${LINENO} #"
    if [ ! -z "${ip_protocol}" ]; then
        sig_protocol="IPv4"
        mgmt_protocol="IPv4"
        if [ "${ip_protocol^^}" == "IPV6/IPV4" ]; then
            sig_protocol="IPv6"
            mgmt_protocol="IPv6"
            doIPv6=1
        else
            if [ "${ip_protocol^^}" == "IPV4/IPV6" ]; then
                doIPv6=1
            fi
        fi
    fi
fi

#Debugging
printf "Debug info (current ifconfig & route):\n" 2>&1 | sed -e 's#^#   #'
printf "sig_protocol=${sig_protocol}, doIPv6=${doIPv6}\n" 2>&1 | sed -e "s#^#     ${LINENO} #"
ifconfig 2>&1 | sed -e "s#^#     ${LINENO} #"
route 2>&1 | sed -e "s#^#     ${LINENO} #"
ls -lart /var/lib/dhcp 2>&1 | sed -e "s#^#     ${LINENO} #"

# Figure out which NIC is for management
let "i=0"
while [ $i -lt $(ip addr show|grep "eth[0-9]:"|wc -l) ]; do
    nic_mac=$(ip addr show dev eth$i|grep link/ether|awk '{print $2}')
    if [ -z "$mgmt_nic" ]; then
        if [[ -z "${mgmt_mac_address}" || "${nic_mac^^}" == "${mgmt_mac_address^^}" ]]; then
            mgmt_nic=eth$i
        fi
    fi

    let "i=$i + 1"
done
if [ -z "$mgmt_nic" ]; then
    err "ERROR: Couldn't determine management NIC!"
fi

# Figure out which NIC is signaling
let "i=0"
while [ $i -lt $(ip addr show|grep "eth[0-9]:"|wc -l) ]; do
    nic_mac=$(ip addr show dev eth$i|grep link/ether|awk '{print $2}')
    if [ "$mgmt_nic" != "eth$i" ]; then
        if [ -z "$sig_nic" ]; then
            if [[ -z "${sig_mac_address}" || "${nic_mac^^}" == "${sig_mac_address^^}" ]]; then
                sig_nic=eth$i
            fi
        fi
    fi

    let "i=$i + 1"
done
if [ -z "$sig_nic" ]; then
    if [ -z "${sig_mac_address}" ]; then
        sig_nic=$mgmt_nic
    else
        if [ "${sig_mac_address^^}" == "${mgmt_mac_address^^}" ]; then
            sig_nic=$mgmt_nic
        else
            err "ERROR: Couldn't determine signaling NIC!"
        fi
    fi
fi

# Log the results
log "mgmt_nic=$mgmt_nic, sig_nic=$sig_nic"

# Get rid of files from the last time
rm -vf /var/lib/cc-ovf/dhcp.${mgmt_nic}-*.env /var/lib/cc-ovf/dhcp.${sig_nic}-*.env 2>&1 | sed -e "s#^#   #"

# Configure the network interface(s) based on the following priority:
#
#   1. DHCP - If not DHCPed, try next
#   2. Environment - If evironment variables don't contain config, try next
#   3. Saved leases - If no previously saved leases, try next
#   4. Prompt - (Time permitting) Prompt the user via the console.
#   5. Halt - Don't start unless all interfaces are configured.
#

# Initialize arrays to store network interface variables.
declare -A mgmt
declare -A sig
declare -A mgmt6
declare -A sig6

mgmt_keys=()
sig_keys=()

# Load up IPv4 network interface variables
for k in fixed_address subnet_mask routers domain_name_servers ntp_servers domain_name domain_search host_name; do
    # Use the loop variable to create a string matching the name of a vApp
    # property that can be indirectly expanded to give the value for the array.

    var=mgmt_${k}
    mgmt[${k}]=${!var}

    if [ ! -z ${mgmt[${k}]} ]; then
        mgmt_keys=( ${mgmt_keys[@]} ${k} )
    fi

    if [[ "$k" != "ntp_servers" && "$k" != "domain_search" && "$k" != "domain_name" && "$k" != "host_name" ]]; then
        var=sig_${k}
        sig[${k}]=${!var}
    else
        if [[ "$k" != "ntp_servers" && "$k" != "domain_search" ]]; then
            sig[${k}]=${mgmt[$k]}
            eval "sig_${k}=${mgmt[$k]}"
        else
            sig[${k}]=
            eval "sig_${k}="
        fi
    fi

    if [ ! -z ${sig[${k}]} ]; then
        sig_keys=( ${sig_keys[@]} ${k} )
    fi
done
mgmt[mac_address]=$(ip addr show dev ${mgmt_nic}|grep link/ether|awk '{print $2}')
sig[mac_address]=$(ip addr show dev ${sig_nic}|grep link/ether|awk '{print $2}')

printf "Debug info:\n" 2>&1 | sed -e 's#^#   #'
declare -p mgmt_keys 2>&1 | sed -e "s#^#     ${LINENO} #"
declare -p sig_keys 2>&1 | sed -e "s#^#     ${LINENO} #"


if [ ${#sig_keys[@]} -ne 0 ]; then
    if [ "${sig_nic}" == "${mgmt_nic}" ]; then
        for k in ${sig_keys[@]}; do
            if [ "${sig[$k]}" != "${mgmt[$k]}" ]; then
                err "ERROR: Signaling IP settings are invalid when management and signaling interfaces are the same!"
            fi
        done
    fi
fi

mgmt6_keys=()
sig6_keys=()

# Load up IPv6 network interface variables
for k in fixed_address prefix_len routers domain_name_servers ntp_servers domain_search; do
    var=mgmt6_${k}
    mgmt6[${k}]=${!var}

    if [ ! -z ${mgmt[${k}]} ]; then
        mgmt6_keys=( ${mgmt6_keys[@]} ${k} )
    fi

    if [[ "$k" != "ntp_servers" && "$k" != "domain_search" && "$k" != "domain_name" && "$k" != "host_name" ]]; then
        var=sig6_${k}
        sig6[${k}]=${!var}
    else
        if [[ "$k" != "ntp_servers" && "$k" != "domain_search" ]]; then
            sig6[${k}]=${mgmt[$k]}
            eval "sig6_${k}=${mgmt[$k]}"
        else
            sig6[${k}]=
            eval "sig6_${k}="
        fi
    fi

    if [ ! -z ${sig6[${k}]} ]; then
        sig6_keys=( ${sig6_keys[@]} ${k} )
    fi
done
mgmt6[mac_address]=$(ip addr show dev ${mgmt_nic}|grep link/ether|awk '{print $2}')
sig6[mac_address]=$(ip addr show dev ${sig_nic}|grep link/ether|awk '{print $2}')

if [ ${#sig6_keys[@]} -ne 0 ]; then
    if [ "${sig6_nic}" == "${mgmt6_nic}" ]; then
        declare -p sig6 2>&1 | sed -e "s#^#     ${LINENO} #"
        err "ERROR: Signaling IPv6 settings are invalid when management and signaling interfaces are the same!"
    fi
fi

#Debugging
printf "Debug info (NIC variables):\n" 2>&1 | sed -e 's#^#   #'
declare -p mgmt 2>&1 | sed -e "s#^#     ${LINENO} #"
declare -p sig 2>&1 | sed -e "s#^#     ${LINENO} #"
declare -p mgmt6 2>&1 | sed -e "s#^#     ${LINENO} #"
declare -p sig6 2>&1 | sed -e "s#^#     ${LINENO} #"

# If environment contains a fixed address for a network interface, delete
# its saved lease.
if [ ! -z "${mgmt[fixed_address]}" ]; then
    rm -f /var/lib/cc-ovf/${mgmt_nic}-ipv4.lease
fi
if [ ! -z "${mgmt6[fixed_address]}" ]; then
    rm -f /var/lib/cc-ovf/${mgmt_nic}-ipv6.lease
fi
if [ ! -z "${sig[fixed_address]}" ]; then
    rm -f /var/lib/cc-ovf/${sig_nic}-ipv4.lease
fi
if [ ! -z "${sig6[fixed_address]}" ]; then
    rm -f /var/lib/cc-ovf/${sig_nic}-ipv6.lease
fi

declare -a nics
nics=( ${mgmt_nic} )
if [ "${sig_nic}" != "${mgmt_nic}" ]; then
    nics=( ${mgmt_nic} ${sig_nic} )
fi

# Set the kernel 'Accept Router Advertisements' property for both interfaces to
# 'Accept if forwarding is disabled'. Property used for Stateless address
# autoconfiguration (SLAAC)
echo 1 > /proc/sys/net/ipv6/conf/${sig_nic}/accept_ra
echo cat /proc/sys/net/ipv6/conf/${sig_nic}/accept_ra 2>&1 | sed -e "s#^#   #"
cat /proc/sys/net/ipv6/conf/${sig_nic}/accept_ra 2>&1 | sed -e "s#^#   #"
if [ "${sig_protocol^^}" == "IPV6" ]; then
    doIPv6=1
fi

echo 1 > /proc/sys/net/ipv6/conf/${mgmt_nic}/accept_ra
echo cat /proc/sys/net/ipv6/conf/${mgmt_nic}/accept_ra 2>&1 | sed -e "s#^#   #"
cat /proc/sys/net/ipv6/conf/${mgmt_nic}/accept_ra 2>&1 | sed -e "s#^#   #"
if [ "${mgmt_protocol^^}" == "IPV6" ]; then
    doIPv6=1
fi

echo killall dhclient 2>&1 | sed -e "s#^#     ${LINENO} #"
killall dhclient 2>&1 | sed -e "s#^#     ${LINENO} #"
echo rm -vf /var/run/dhclient*.pid 2>&1 | sed -e "s#^#     ${LINENO} #"
rm -vf /var/run/dhclient*.pid 2>&1 | sed -e "s#^#     ${LINENO} #"
echo service networking restart 2>&1 | sed -e "s#^#     ${LINENO} #"
service networking restart 2>&1 | sed -e "s#^#     ${LINENO} #"


###############################################################################
# IP Configuration:                                                           #
#     We use DHCP through 'dhclient' to configure all network interfaces      #
#     (initially in the management namespace) then move the signalling        #
#     interface to its own namespace. Doing this removes any config and so we #
#     re-configure it later on.                                               #
###############################################################################

# IPv4 self configuration
if [ $doIPv4 -ne 0 ]; then
    sed -ie '/#### cc-ovf IPv4 interfaces begin ####/,/#### cc-ovf IPv4 interfaces end ####/d' /etc/dhcp/dhclient.conf
    printf "#### cc-ovf IPv4 interfaces begin ####\n" >> /etc/dhcp/dhclient.conf

    # Build dhclient.conf interface section for values that
    # supersede what DHCP gives us for IPv4
    for nic in ${nics[@]}; do
        if [ "${nic}" == "${mgmt_nic}" ]; then
            eth_str=$(declare -p mgmt)
            key_str=$(declare -p mgmt_keys)
        else
            eth_str=$(declare -p sig)
            key_str=$(declare -p sig_keys)
        fi
        eval "declare -A eth="${eth_str#*=}
        eval "declare -A keys="${key_str#*=}

        #Debugging
        printf "Debug info:\n" 2>&1 | sed -e 's#^#   #'
        declare -p eth 2>&1 | sed -e "s#^#     ${LINENO} #"
        declare -p keys 2>&1 | sed -e "s#^#     ${LINENO} #"

        if [ ${#keys[@]} -ne 0 ]; then
            printf "interface \"${nic}\" {\n" >> /etc/dhcp/dhclient.conf
            for k in ${keys[@]}; do
                case $k in
                    subnet_mask)
                      printf "  supersede subnet-mask ${eth[$k]};\n" >> /etc/dhcp/dhclient.conf
                      ;;
                    routers)
                      printf "  supersede routers ${eth[$k]};\n" >> /etc/dhcp/dhclient.conf
                      ;;
                    domain_name_servers)
                      printf "  supersede domain-name-servers ${eth[$k]};\n" >> /etc/dhcp/dhclient.conf
                      ;;
                    ntp_servers)
                      printf "  supersede ntp-servers ${eth[$k]};\n" >> /etc/dhcp/dhclient.conf
                      ;;
                    domain_name)
                      printf "  supersede domain-name \"${eth[$k]}\";\n" >> /etc/dhcp/dhclient.conf
                      ;;
                    domain_search)
                      printf "  supersede domain-search \"${eth[$k]}\";\n" >> /etc/dhcp/dhclient.conf
                      ;;
                    host_name)
                      printf "  supersede host-name ${eth[$k]};\n" >> /etc/dhcp/dhclient.conf
                      ;;
                esac
            done
            printf "}\n" >> /etc/dhcp/dhclient.conf
        fi
    done

    printf "#### cc-ovf IPv4 interfaces end ####\n" >> /etc/dhcp/dhclient.conf

    # Force release of leases and install static fallback leases, if available
    dhclient -4 -r >> /var/log/ovf-sc.dhclient-4.log 2>&1
    rm -vf /var/lib/dhcp/dhclient.*leases 2>&1 | sed -e "s#^#   #"
    for lease in $(find /var/lib/cc-ovf \( -name "${mgmt_nic}-ipv4.lease" -o -name "${sig_nic}-ipv4.lease" \)); do
        cat ${lease} >> /var/lib/dhcp/dhclient.leases
    done

    # Try DHCP again on all interfaces
    log "Retrying DHCP for ${mgmt_nic}..."
    dhclient -1 -v ${mgmt_nic} >> /var/log/ovf-sc.dhclient-4.log 2>&1
    if [ "${sig_nic}" != "${mgmt_nic}" ]; then
        log "Retrying DHCP for ${sig_nic}..."
        dhclient -1 -v ${sig_nic} >> /var/log/ovf-sc.dhclient-4.log 2>&1
    fi

    # Debugging
    printf "Debug info (current DHCP leases):\n" 2>&1 | sed -e 's#^#   #'
    cat /var/lib/dhcp/dhclient.leases 2>&1 | sed -e "s#^#     ${LINENO} #"

    # Capture leases as fallback lease for next boot
    for nic in ${nics[@]}; do
        rm -vf /var/lib/cc-ovf/${nic}-ipv4.lease 2>&1 | sed -e "s#^#   #"
        sed -n "/interface \"${nic}\"/,/}/p" /var/lib/dhcp/dhclient.leases 2> /dev/null | sed -e 's#\(renew\|rebind\|expire\).*#\1 4 2037/12/31 00:00:00;#' > /tmp/${nic}-ipv4.lease
        if [ -s /tmp/${nic}-ipv4.lease ]; then
            lno=$(grep -n interface /tmp/${nic}-ipv4.lease|tail -1|gawk -F: -e '{print $1}')
            sed -n -ie "$lno,\$p" /tmp/${nic}-ipv4.lease
            echo "lease {" > /var/lib/cc-ovf/${nic}-ipv4.lease
            cat /tmp/${nic}-ipv4.lease >> /var/lib/cc-ovf/${nic}-ipv4.lease
        fi
    done

    printf "Debug info (our saved leases):\n" 2>&1 | sed -e 's#^#   #'
    ls -la /var/lib/cc-ovf 2>&1 | sed -e "s#^#     ${LINENO} #"
    no_leases=$(find /var/lib/cc-ovf \( -name "${mgmt_nic}-ipv4.lease" -o -name "${sig_nic}-ipv4.lease" \)|wc -l)
    echo "no_leases=${no_leases}" 2>&1 | sed -e "s#^#     ${LINENO} #"

    if [ $no_leases -ne ${#nics[@]} ]; then
        # We don't have a lease for all interfaces, so we'll build the missing
        # ones from the environment variables and then give it another try.
        for nic in ${nics[@]}; do
            if [ ! -e /var/lib/cc-ovf/${nic}-ipv4.lease ]; then
                log "INFO: Missing network configuration for ${nic}"
                if [ "${nic}" == "${mgmt_nic}" ]; then
                    eth_str=$(declare -p mgmt)
                else
                    eth_str=$(declare -p sig)
                fi
                eval "declare -A eth="${eth_str#*=}

                #Debugging
                printf "Debug info (NIC ${nic}):\n" 2>&1 | sed -e 's#^#   #'
                declare -p eth 2>&1 | sed -e "s#^#     ${LINENO} #"

                if [ ! -z "${eth[fixed_address]}" ]; then
                    printf "\
lease {\n\
  interface \"${nic}\";\n\
  fixed-address ${eth[fixed_address]};\n\
" > /var/lib/cc-ovf/${nic}-ipv4.lease
                    if [ ! -z ${eth[subnet_mask]} ]; then
                        printf "\
  option subnet-mask ${eth[subnet_mask]};\n\
" >> /var/lib/cc-ovf/${nic}-ipv4.lease
                    fi
                    if [ ! -z ${eth[routers]} ]; then
                        printf "\
  option routers ${eth[routers]};\n\
" >> /var/lib/cc-ovf/${nic}-ipv4.lease
                    fi
                    if [ ! -z ${eth[domain_name_servers]} ]; then
                        printf "\
  option domain-name-servers ${eth[domain_name_servers]};\n\
" >> /var/lib/cc-ovf/${nic}-ipv4.lease
                    fi
                    if [ ! -z ${eth[ntp_servers]} ]; then
                        printf "\
  option ntp-servers ${eth[ntp_servers]};\n\
" >> /var/lib/cc-ovf/${nic}-ipv4.lease
                    fi
                    if [ ! -z ${eth[domain_name]} ]; then
                        printf "\
  option domain-name \"${eth[domain_name]}\";\n\
" >> /var/lib/cc-ovf/${nic}-ipv4.lease
                    fi
                    if [ ! -z ${eth[domain_search]} ]; then
                        printf "\
  option domain-search \"${eth[domain_search]}\";\n\
" >> /var/lib/cc-ovf/${nic}-ipv4.lease
                    fi
                    if [ ! -z ${eth[host_name]} ]; then
                        printf "\
  option host-name \"${eth[host_name]}\";\n\
" >> /var/lib/cc-ovf/${nic}-ipv4.lease
                    fi
                    printf "\
  renew 4 2037/12/31 00:00:00;\n\
  rebind 4 2037/12/31 00:00:00;\n\
  expire 4 2037/12/31 00:00:00;\n\
}\n\
" >> /var/lib/cc-ovf/${nic}-ipv4.lease
                    sed -ie '/#### cc-ovf IPv4 leases begin ####/,/#### cc-ovf IPv4 leases end ####/d' /etc/dhcp/dhclient.conf
                    printf "#### cc-ovf IPv4 leases begin ####\n" >> /etc/dhcp/dhclient.conf
                    for lease in $(find /var/lib/cc-ovf \( -name "${mgmt_nic}-ipv4.lease" -o -name "${sig_nic}-ipv4.lease" \)); do
                        cat $lease >> /etc/dhcp/dhclient.conf
                    done
                    printf "#### cc-ovf IPv4 leases end ####\n" >> /etc/dhcp/dhclient.conf
                    cat /etc/dhcp/dhclient.conf 2>&1 | sed -e "s#^#     ${LINENO} #"
                    log "Retrying DHCP for ${nic} to pickup values from properties..."
                    dhclient -4 -v -1 ${nic}  2>&1 | tee -a /var/log/ovf-sc.dhclient-4.log 2>&1 | sed -e "s#^#     ${LINENO} #"
                fi
            fi
        done

        # If after manufacturing leases from the environment we're still missing some,
        # call it quits, declare an error and wait for operator intervention.
        if [ "$(find /var/lib/cc-ovf \( -name "${mgmt_nic}-ipv4.lease" -o -name "${sig_nic}-ipv4.lease" \)|wc -l)" -ne ${#nics[@]} ]; then
            err "ERROR: Can't determine network configuration!"
        fi
    fi
fi

# IPv6 self configuration
if [ $doIPv6 -ne 0 ]; then
    # FIXME: Need to do superseds for IPv6

    # Force release of leases and install static fallback leases, if available
    log "Releasing DHCP6 leases..."
    killall dhclient > /dev/null 2>&1
    dhclient -6 -r -1 >> /var/log/ovf-sc.dhclient-6.log 2>&1
    rm -vf /var/lib/dhcp/dhclient6.*leases 2>&1 | sed -e "s#^#   #"
    for lease in $(find /var/lib/cc-ovf \( -name "${mgmt_nic}-ipv6.lease" -o -name "${sig_nic}-ipv6.lease" \)); do
        cat ${lease} >> /var/lib/dhcp/dhclient6.leases
    done
    printf "Debug info (current DHCP6 leases):\n" 2>&1 | sed -e 's#^#   #'
    cat /var/lib/dhcp/dhclient6.leases 2>&1 | sed -e "s#^#     ${LINENO} #"

    # Try DHCP6 again on all interfaces
    log "Retrying DHCP6 for ${mgmt_nic}..."
    killall dhclient > /dev/null 2>&1
    dhclient -6 -v -1 ${mgmt_nic} >> /var/log/ovf-sc.dhclient-6.log 2>&1
    if [ "${sig_nic}" != "${mgmt_nic}" ]; then
        log "Retrying DHCP6 for ${sig_nic}..."
        killall dhclient > /dev/null 2>&1
        dhclient -6 -v -1 ${sig_nic} >> /var/log/ovf-sc.dhclient-6.log 2>&1
    fi

    # Debugging
    printf "Debug info (current DHCP6 leases):\n" 2>&1 | sed -e 's#^#   #'
    cat /var/lib/dhcp/dhclient6.leases 2>&1 | sed -e "s#^#     ${LINENO} #"

    # Capture leases as fallback lease for next boot
    for nic in ${nics[@]}; do
        rm -vf /var/lib/cc-ovf/${nic}-ipv6.lease 2>&1 | sed -e "s#^#   #"
        sed -n "/interface \"${nic}\"/,/^}/p" /var/lib/dhcp/dhclient6.leases 2> /dev/null | sed -e "s/\(preferred-life\|max-life\)[[:space:]]*.*;$/\1 4294967295;/" > /tmp/${nic}-ipv6.lease
        if [ -s /tmp/${nic}-ipv6.lease ]; then
            lno=$(grep -n interface /tmp/${nic}-ipv6.lease|tail -1|gawk -F: -e '{print $1}')
            sed -n -ie "$lno,\$p" /tmp/${nic}-ipv6.lease
            echo "lease6 {" > /var/lib/cc-ovf/${nic}-ipv6.lease
            cat /tmp/${nic}-ipv6.lease >> /var/lib/cc-ovf/${nic}-ipv6.lease
        fi
    done

    printf "Debug info (our saved leases):\n" 2>&1 | sed -e 's#^#   #'
    ls -la /var/lib/cc-ovf 2>&1 | sed -e "s#^#     ${LINENO} #"
    no_leases=$(find /var/lib/cc-ovf \( -name "${mgmt_nic}-ipv6.lease" -o -name "${sig_nic}-ipv6.lease" \)|wc -l)
    echo "no_leases=${no_leases}" 2>&1 | sed -e "s#^#     ${LINENO} #"

    if [ $no_leases -ne ${#nics[@]} ]; then
        # We don't have a lease for all interfaces, so we'll build the missing
        # ones from the environment variables and then give it another try.
        for nic in ${nics[@]}; do
            if [ ! -e /var/lib/cc-ovf/${nic}-ipv6.lease ]; then
                log "INFO: Missing network configuration for ${nic}"
                if [ "${nic}" == "${mgmt_nic}" ]; then
                    eth_str=$(declare -p mgmt6)
                else
                    eth_str=$(declare -p sig6)
                fi
                eval "declare -A eth="${eth_str#*=}

                #Debugging
                printf "Debug info (NIC ${nic}):\n" 2>&1 | sed -e 's#^#   #'
                declare -p eth 2>&1 | sed -e "s#^#     ${LINENO} #"

                if [ ! -z "${eth[fixed_address]}" ]; then
                    declare -a mac
                    mac=( $(echo ${eth[mac_address]} | sed -e 's#:# #g' ) )
                    printf "\
lease6 {\n\
  interface \"${nic}\";\n\
  ia-na ${mac[2]}:${mac[3]}:${mac[4]}:${mac[5]} {\n\
    starts $(date +%s);\n\
    renew 0;\n\
    rebind 0;\n\
    iaaddr ${eth[fixed_address]} {\n\
      starts $(date +%s);\n\
      preferred-life 4294967295;\n\
      max-life 4294967295;\n\
    }\n\
  }\n\
  option dhcp6.server-id 0:1:2:3:4:5:6:7:8:9:0:1:2:3;\n\
  option dhcp6.client-id cc:cc:cc:1:0:${mac[1]}:${mac[2]}:${mac[3]}:${mac[4]}:${mac[5]};\n\
  option dhcp6.name-servers ${eth[domain_name_servers]};\n\
" > /var/lib/cc-ovf/${nic}-ipv6.lease
                    if [ ! -z ${eth[domain_search]} ]; then
                        printf "\
  option dhcp6.domain-search \"${eth[domain_search]}\";\n\
" >> /var/lib/cc-ovf/${nic}-ipv6.lease
                    fi
                    if [ ! -z ${eth[ntp_servers]} ]; then
                        printf "\
  option dhcp6.sntp-servers ${eth[ntp_servers]};\n\
" >> /var/lib/cc-ovf/${nic}-ipv6.lease
                    fi
                    printf "\
}\n\
" >> /var/lib/cc-ovf/${nic}-ipv6.lease
                    sed -ie '/#### cc-ovf IPv6 leases begin ####/,/#### cc-ovf IPv6 leases end ####/d' /etc/dhcp/dhclient.conf
                    printf "#### cc-ovf IPv6 leases begin ####\n" >> /etc/dhcp/dhclient.conf
                    for lease in $(find /var/lib/cc-ovf \( -name "${mgmt_nic}-ipv6.lease" -o -name "${sig_nic}-ipv6.lease" \)); do
                        cat $lease >> /etc/dhcp/dhclient.conf
                    done
                    printf "#### cc-ovf IPv6 leases end ####\n" >> /etc/dhcp/dhclient.conf
                    cat /etc/dhcp/dhclient.conf 2>&1 | sed -e "s#^#     ${LINENO} #"
                    log "Retrying DHCP6 for ${nic} to pickup values from properties..."
                    killall dhclient > /dev/null 2>&1
                    dhclient -6 -v -1 ${nic}  2>&1 | tee -a /var/log/ovf-sc.dhclient-6.log 2>&1 | sed -e "s#^#     ${LINENO} #"
                fi
            fi
        done

        # If after manufacturing leases from the environment we're still missing some,
        # call it quits, declare an error and wait for operator intervention.
        if [ "$(find /var/lib/cc-ovf \( -name "${mgmt_nic}-ipv6.lease" -o -name "${sig_nic}-ipv6.lease" \)|wc -l)" -ne ${#nics[@]} ]; then
            err "ERROR: Can't determine network configuration!"
        fi
    fi
fi

# Debugging
printf "Debug info (current listing of leases):\n" 2>&1 | sed -e 's#^#   #'
ls -lart /var/lib/cc-ovf/*.lease 2>&1 | sed -e "s#^#     ${LINENO} #"
ls -lart /var/lib/cc-ovf/eth*.lease 2>&1 | sed -e "s#^#     ${LINENO} #"
ls -lart /var/lib/dhcp/*.leases 2>&1 | sed -e "s#^#     ${LINENO} #"

printf "Debug info (current ifconfig and route table):\n" 2>&1 | sed -e 's#^#   #'
ifconfig 2>&1 | sed -e "s#^#     ${LINENO} #"
route -4 2>&1 | sed -e "s#^#     ${LINENO} #"
route -6 2>&1 | sed -e "s#^#     ${LINENO} #"

# Setup dual NICs (if present)
mgmt_ip4=$( ip -4 addr show dev ${mgmt_nic}|grep global|sed -e 's#^.*inet* \([^/]*\)/.*$#\1#' )
mgmt_ip6=$( ip -6 addr show dev ${mgmt_nic}|grep global|sed -e 's#^.*inet6* \([^/]*\)/.*$#\1#' )
mgmt_ip=${mgmt_ip4}
tmp_ip=( $mgmt_ip )
if [ ${#tmp_ip[@]} -ne 1 ]; then
    echo ip -4 addr show dev ${mgmt_nic} 2>&1 | sed -e 's#^#   #'
    ip -4 addr show dev ${mgmt_nic} 2>&1 | sed -e 's#^#   #'
    err "ERROR: Can't determine management network configuration - too many IPv4 addresses!"
fi
if [ "${mgmt_protocol^^}" == "IPV6" ]; then
    mgmt_ip=${mgmt_ip6}
fi
if [ ! -z "${mgmt_ip6}" ]; then
    if [ -z "${mgmt_ip4}" ]; then
        err "ERROR: Both IPv6 and IPv4 must be configured for management interface! Halting ..."
    fi
fi

sig_ip4=$( ip -4 addr show dev ${sig_nic}|grep global|sed -e 's#^.*inet* \([^/]*\)/.*$#\1#' )
sig_ip6=$( ip -6 addr show dev ${sig_nic}|grep global|sed -e 's#^.*inet6* \([^/]*\)/.*$#\1#' )
sig_ip=${sig_ip4}
tmp_ip=( $sig_ip )
if [ ${#tmp_ip[@]} -ne 1 ]; then
    echo ip -4 addr show dev ${sig_nic} 2>&1 | sed -e 's#^#   #'
    ip -4 addr show dev ${sig_nic} 2>&1 | sed -e 's#^#   #'
    err "ERROR: Can't determine signaling network configuration - too many IPv4 addresses!"
fi
if [ "${sig_protocol^^}" == "IPV6" ]; then
    sig_ip=${sig_ip6}
fi
if [ ! -z "${sig_ip6}" ]; then
    if [ -z "${sig_ip4}" ]; then
        err "ERROR: Both IPv6 and IPv4 must be configured for signaling interface! Halting ..."
    fi
fi

for nic in ${nics[@]}; do
    if [ "${nic}" == "${mgmt_nic}" ]; then
        eth_str=$(declare -p mgmt)
    else
        eth_str=$(declare -p sig)
    fi
    eval "declare -A eth="${eth_str#*=}

    if [ -r /var/lib/cc-ovf/dhcp.${nic}-ipv4.env ]; then
        . /var/lib/cc-ovf/dhcp.${nic}-ipv4.env
        if [ ! -z "${mgmt[fixed_address]}" ]; then
            new_ip_address=${mgmt[fixed_address]}
            echo ip -4 addr flush dev ${nic} label ${nic} 2>&1 | sed -e 's#^#   #'
            ip -4 addr flush dev ${nic} label ${nic} 2>&1 | sed -e 's#^#   #'
            echo ip -4 addr add ${new_ip_address}${new_subnet_mask:+/$new_subnet_mask} ${new_broadcast_address:+broadcast $new_broadcast_address} dev ${interface} label ${interface} 2>&1 | sed -e 's#^#   #'
            ip -4 addr add ${new_ip_address}${new_subnet_mask:+/$new_subnet_mask} ${new_broadcast_address:+broadcast $new_broadcast_address} dev ${interface} label ${interface} 2>&1 | sed -e 's#^#   #'
            echo arping -c2 -A -I eth0 ${new_ip_address} 2>&1 | sed -e 's#^#   #'
            arping -c2 -A -I eth0 ${new_ip_address} 2>&1 | sed -e 's#^#   #'

            # set intf_metric if IF_METRIC is set or there's more than one router
            intf_metric="$IF_METRIC"
            if [ "${new_routers%% *}" != "${new_routers}" ]; then
                intf_metric=${intf_metric:-1}
            fi
            for router in $new_routers; do
                if [ "$new_subnet_mask" = "255.255.255.255" ]; then
                # point-to-point connection => set explicit route
                    echo ip -4 route add ${router} dev $interface 2>&1 | sed -e 's#^#   #'
                    ip -4 route add ${router} dev $interface 2>&1 | sed -e 's#^#   #'
                fi

            # set default route
                echo ip -4 route add default via ${router} dev ${interface} \
                    ${intf_metric:+metric $intf_metric}  2>&1 | sed -e 's#^#   #'
                ip -4 route add default via ${router} dev ${interface} \
                    ${intf_metric:+metric $intf_metric}  2>&1 | sed -e 's#^#   #'

                echo ping -c1 ${router} 2>&1 | sed -e 's#^#   #'
                ping -c1 ${router} 2>&1 | sed -e 's#^#   #'
            done
        fi
    fi
done

# FIXME: Need to do above for IPv6
if [ -r /var/lib/cc-ovf/dhcp.${mgmt_nic}-ipv6.env ]; then
    . /var/lib/cc-ovf/dhcp.${mgmt_nic}-ipv6.env
fi
if [ -r /var/lib/cc-ovf/dhcp.${sig_nic}-ipv6.env ]; then
    . /var/lib/cc-ovf/dhcp.${sig_nic}-ipv6.env
fi

# Send gratuitous ARP(s) for IPv4
echo arping -c2 -A -I ${mgmt_nic} ${mgmt_ip4} 2>&1 | sed -e 's#^#   #'
arping -c2 -A -I ${mgmt_nic} ${mgmt_ip4} 2>&1 | sed -e 's#^#   #'
if [ "${mgmt_nic}" != "${sig_nic}" ]; then
    echo arping -c2 -A -I ${sig_nic} ${sig_ip4} 2>&1 | sed -e 's#^#   #'
    arping -c2 -A -I ${sig_nic} ${sig_ip4} 2>&1 | sed -e 's#^#   #'
fi

if [[ "${sig_nic}" != "${mgmt_nic}" && ! -z "$new_domain_name_servers" ]]; then
    log "INFO: Configuring signaling network namespace"

    echo_and_run ip netns add signaling 2>&1 | sed -e 's#^#   #'
    echo_and_run ip link set ${sig_nic} netns signaling 2>&1 | sed -e 's#^#   #'
    echo_and_run ip netns exec signaling ifconfig lo up 2>&1 | sed -e 's#^#   #'

    # $new_subnet_mask is configured from /var/lib/cc-ovf/dhcp.eth1-ipv4.env
    # which we read further up and contains either the vApp property or that
    # received from DHCP.
    echo_and_run ip netns exec signaling ifconfig ${sig_nic} ${sig_ip4} netmask ${new_subnet_mask} up 2>&1 | sed -e 's#^#   #'
    if [ ! -z "${sig_ip6}" ]; then
        echo_and_run ip netns exec signaling ifconfig eth1 inet6 add ${sig_ip6}/${new_ip6_prefixlen} up 2>&1 | sed -e 's#^#   #'
    fi

    echo_and_run ip netns exec signaling route add default gateway $new_routers dev ${sig_nic} 2>&1 | sed -e 's#^#   #'
    mkdir -p /etc/netns/signaling
    if [ "${sig_protocol^^}" == "IPV6" ]; then
        printf "nameserver $new_dhcp6_name_servers\n" > /etc/netns/signaling/resolv.conf
    else
        printf "nameserver $new_domain_name_servers\n" > /etc/netns/signaling/resolv.conf
    fi
    printf "Debug info (signaling netns routing table):\n" 2>&1 | sed -e 's#^#   #'
    echo_and_run ip netns exec signaling route 2>&1 | sed -e "s#^#     ${LINENO} #"
    echo_and_run ip netns 2>&1 | sed -e 's#^#   #'

    (
        . /var/lib/cc-ovf/dhcp.${mgmt_nic}-ipv4.env
        echo_and_run route add default gateway $new_routers dev ${mgmt_nic} 2>&1 | sed -e 's#^#   #'
    )
fi

echo route 2>&1 | sed -e "s#^#     ${LINENO} #"
route 2>&1 | sed -e "s#^#     ${LINENO} #"

echo killall dhclient 2>&1 | sed -e "s#^#     ${LINENO} #"
killall dhclient 2>&1 | sed -e "s#^#     ${LINENO} #"
echo rm -vf /var/run/dhclient*.pid 2>&1 | sed -e "s#^#     ${LINENO} #"
rm -vf /var/run/dhclient*.pid 2>&1 | sed -e "s#^#     ${LINENO} #"
echo service networking restart 2>&1 | sed -e "s#^#     ${LINENO} #"
service networking restart 2>&1 | sed -e "s#^#     ${LINENO} #"

# Function for substituting our variables into config files
declare -A vars
vars[signaling_ip]=${sig_ip}
vars[signaling_ip]=${sig_ip}
if [ "${ip_protocol^^}" == "IPV6/IPV4" ]; then
    vars[signaling_ip_qual]="[${sig_ip}]"
    vars[signaling_ip_qual]="[${sig_ip}]"
else
    vars[signaling_ip_qual]="${sig_ip}"
    vars[signaling_ip_qual]="${sig_ip}"
fi
vars[mgmt_ip]=${mgmt_ip}
vars[etcd_cluster]=${etcd_cluster}
vars[local_site_name]=${local_site_name}
vars[remote_site_name]=${remote_site_name}
vars[mgmt_protocol]=${mgmt_protocol}
vars[sig_protocol]=${sig_protocol}

subst_vars()
{
    log "subst_vars $*"
    for k in "${!vars[@]}"; do
        for f in "$*"; do
            sed --in-place=.ovf~ -e "s#\$[[]${k}[]]#${vars[$k]}#g" "$f"
            rm -f "$f.ovf~"
        done
    done
}

cfg_dev=$(find_payload)

# Check to see if Clearwater is install and if not don't do much.
# If Clearwater is installed then perform self-configuration per
# VA properties or what we find on the CD.
dpkg-query -W 2>&1 |grep -q clearwater
if [ $? -ne 0 ]; then
    log "INFO: Clearwater not installed - Skipping customizations"
    if [ -d /var/clearwater/default.cfg ]; then
        (
            log "INFO: Copying /var/clearwater/default.cfg to /"
            cd /var/clearwater/default.cfg
            cp -rvp . / 2>&1 | sed -e 's#^#   #'
        )
    fi
else
    if [ -z $cfg_dir ]; then
        mkdir -p /mnt/ovf.cfg
        mount ${cfg_dev} /mnt/ovf.cfg > /dev/null 2>&1
        if [ $? -eq 0 ]; then
            if [ -d /mnt/ovf.cfg/payload ]; then
                cfg_dir="$(basename ${cfg_dev}):/payload"
            fi
            umount ${cfg_dev} > /dev/null 2>&1
        fi
    fi
    cc_dirs=(/etc/chronos /etc/cassandra /etc/clearwater)
    if [ ! -z $cfg_dir ]; then
        cfg_loc=( $(echo $cfg_dir|sed -e 's#:# #g'|sed -e 's#\r##g') )
        if [ "${#cfg_loc[@]}" != "2" ];then
            if [ "${#cfg_loc[@]}" != 1 ];then
                err "ERROR: Invalid format of 'cfg_dir' ($cfg_dir) property. Halting ..."
            else
                cfg_loc=${cfg_loc[0]}
            fi
        else
            cfg_dev=/dev/${cfg_loc[0]}
            cfg_loc=${cfg_loc[1]}
        fi
        if [ ! -z "$cfg_dev" ]; then
            mkdir -p /mnt/ovf.cfg
            mount ${cfg_dev} /mnt/ovf.cfg 2>&1 | sed -e 's#^#   #'
        fi
        if [ $? -ne 0 ]; then
            err "ERROR: Cannot mount ${cfg_dev}. Halting ..."
        fi
        if [ ! -f /mnt/ovf.cfg/${cfg_loc} ]; then
            if [ ! -d /mnt/ovf.cfg/${cfg_loc} ]; then
                if [ ! -z "$cfg_dev" ]; then
                    umount ${cfg_dev} 2>&1 | sed -e 's#^#   #'
                fi
                err "ERROR: Invalid/missing config - ${cfg_loc}. Halting ..."
            fi
            cfg_dir="/mnt/ovf.cfg/${cfg_loc}"
        else
            rm -rf /var/lib/cc-ovf/ovf.cfg
            mkdir -p /var/lib/cc-ovf/ovf.cfg
            tar zvxf /mnt/ovf.cfg/${cfg_loc} -C /var/lib/cc-ovf/ovf.cfg > /dev/null 2>&1
            if [ $? != 0 ]; then
                if [ ! -z "$cfg_dev" ]; then
                    umount ${cfg_dev} 2>&1 | sed -e 's#^#   #'
                fi
                err "ERROR: Invalid tarball - ${cfg_loc}. Halting ..."
            fi
            cfg_dir=/var/lib/cc-ovf/ovf.cfg
        fi

        cfg_newest=$(find ${cfg_dir} -type f -print0|xargs -0 ls -lrt --time-style=+%s|tail -1|awk '{print $6}')

        printf "Debug info:\n" 2>&1 | sed -e 's#^#   #'
        printf "cfg_newest=$cfg_newest (%s)\n" "$(date -u -d @$cfg_newest)" 2>&1 | sed -e "s#^#     ${LINENO} #"

        cfg_md5=$(find ${cfg_dir} -type f -print0|xargs -0 cat|md5sum -b|awk '{print $1}')
        printf "cfg_md5=$cfg_md5\n" 2>&1 | sed -e "s#^#     ${LINENO} #"

        cc_cfg_files=$(find ${cfg_dir} -type f -print 2> /dev/null|egrep -E "($(echo ${cc_dirs[@]}|sed -e 's#[[:space:]]\+#|#g'))")
        noncc_cfg_files=$(find ${cfg_dir} -type f -print 2> /dev/null|egrep -v -E "($(echo ${cc_dirs[@]}|sed -e 's#[[:space:]]\+#|#g'))")
        noncc_cfg_files="${noncc_cfg_files} $(ls -1 ${cfg_dir}/../noncc.* 2> /dev/null)"

        if [ ! -z "$cc_cfg_files" ]; then
            cc_cfg_newest=$(ls -lrt --time-style=+%s ${cc_cfg_files}|tail -1|awk '{print $6}')
            printf "cc_cfg_newest=$cc_cfg_newest (%s)\n" "$(date -u -d @$cc_cfg_newest)" 2>&1 | sed -e "s#^#     ${LINENO} #"
            cc_cfg_md5=$(cat ${cc_cfg_files}|md5sum -b|awk '{print $1}')
            printf "cc_cfg_md5=$cc_cfg_md5\n" 2>&1 | sed -e "s#^#     ${LINENO} #"

            if [ -f /etc/last_cc_cfg ]; then
                last_cc_cfg=( $(cat /etc/last_cc_cfg) )
            else
                last_cc_cfg=( 0 0 )
            fi

            if [ "${last_cc_cfg[0]}" != "${cc_cfg_md5}" ]; then
                (
                    cd ${cfg_dir}
                    cp -rvp --parents $(cd ${cfg_dir}; find . -type f -print 2> /dev/null|egrep -E "($(echo ${cc_dirs[@]}|sed -e 's#[[:space:]]\+#|#g'))") / 2>&1 | sed -e "s#^#     ${LINENO} #"
                )

                printf "${cc_cfg_md5} ${cc_cfg_newest}\n" > /etc/last_cc_cfg
            fi
        fi

        if [ ! -z "$noncc_cfg_files" ]; then
            noncc_cfg_newest=$(ls -lrt --time-style=+%s ${noncc_cfg_files}|tail -1|awk '{print $6}')
            printf "noncc_cfg_newest=$noncc_cfg_newest (%s)\n" "$(date -u -d @$noncc_cfg_newest)" 2>&1 | sed -e "s#^#     ${LINENO} #"
            noncc_cfg_md5=$(cat ${noncc_cfg_files}|md5sum -b|awk '{print $1}')
            printf "noncc_cfg_md5=$noncc_cfg_md5\n" 2>&1 | sed -e "s#^#     ${LINENO} #"

            if [ -f /etc/last_noncc_cfg ]; then
                last_noncc_cfg=( $(cat /etc/last_noncc_cfg) )
            else
                last_noncc_cfg=( 0 0 )
            fi

            if [ "${last_noncc_cfg[0]}" != "${noncc_cfg_md5}" ]; then
                (
                    cd ${cfg_dir}
                    cp -rvp --parents $(cd ${cfg_dir}; find . -type f -print 2> /dev/null|egrep -v -E "($(echo ${cc_dirs[@]}|sed -e 's#[[:space:]]\+#|#g'))") /
                    if [ -x ../noncc.postinst ]; then
                        ../noncc.postinst
                    fi
                )
                printf "${noncc_cfg_md5} ${noncc_cfg_newest}\n" > /etc/last_noncc_cfg
            fi
        fi

        if [ ! -z "$cfg_dev" ]; then
            umount ${cfg_dev}
        fi
    fi

    subst_files=($(find ${cc_dirs[@]} -type f -print0 2> /dev/null|xargs -0 grep -l "\$[[][^]]*[]]"))
    if [ "${#subst_files[@]}" -gt "0" ]; then
        grep -q "\$[[][^]]*[]]" "${subst_files[@]}"; cfg_subst=$?
        for file in ${subst_files[@]}; do
            subst_vars "$file"
        done
        subst_files=($(find ${cc_dirs[@]} -type f -print0 2> /dev/null|xargs -0 grep -l "\$[[][^]]*[]]"))
        if [ "${#subst_files[@]}" -gt "0" ]; then
            err "ERROR: Invalid substitutions found:" "$(find ${cc_dirs[@]} -type f -print0|xargs -0 grep -n "\$[[][^]]*[]]")"
        fi
        printf "Debug info:\n" 2>&1 | sed -e 's#^#   #'
        printf "cfg_subst=$cfg_subst\n" 2>&1 | sed -e "s#^#     ${LINENO} #"
        ls -la /var/lib/clearwater-etcd 2>&1 | sed -e "s#^#     ${LINENO} #"
        if [ $cfg_subst -eq 0 ]; then
            if [ -d /var/lib/clearwater-etcd ]; then
                printf "/var/lib/clearwater-etcd exists\n" 2>&1 | sed -e "s#^#     ${LINENO} #"
                rm -rvf /var/lib/clearwater-etcd/* 2>&1 | sed -e "s#^#     ${LINENO} #"
            fi
        fi
    fi
fi

# We're done!
log "VA customization complete!"

if [ -z "$UPSTART_JOB" ]; then
    # Pause for debugging
    printf "Press <enter> to continue..."
    read RESPONSE
fi

/usr/bin/clearwater-show-config

# Close stdout to flush to the log
exec 1>&-

exit 0
