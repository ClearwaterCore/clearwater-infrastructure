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

set +e

doIPv4=1
doIPv6=0

rm /var/log/ovf-sc.dhclient*.log
touch /var/log/ovf-sc.dhclient-4.log /var/log/ovf-sc.dhclient-6.log

# Send stdout/stderr to a log file
exec >  >( stdbuf -i0 -o0 -e0 tee /var/log/ovf-sc.log )
exec 2>&1

#set -x

# Delay for a few seconds to let other upstart jobs to complete before we begin
sleep 2

# Print banner
printf "\n\
 * Starting Clearwater Core OVF self configuration:\n\
"

# Function for parsing local configuration options
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

# Function for logging to syslog
log() {
    echo "   $*"
    logger "self-config:" "$*"
}

# Function to emit error message and wait for user input
err() {
    echo "   $*"
    logger "self-config:" "$*"
    askQuestion "Press <Enter> to continue..."
    exit 1
}

# Check for VMWare tools
if [ ! -x /usr/bin/vmware-rpctool ]; then
    err "ERROR: VMware Tools are not installed. Exiting ..."
fi
rm -f /var/lib/cc-ovf/ovf.xml
rpctool_stderr=$(/usr/bin/vmware-rpctool 'info-get guestinfo.ovfEnv' >/var/lib/cc-ovf/ovf.xml 2> /var/lib/cc-ovf/$$; cat /var/lib/cc-ovf/$$; rm -f /var/lib/cc-ovf/$$)
if [ ! -s /var/lib/cc-ovf/ovf.xml ]; then
    if [ "$rpctool_stderr" == "Failed sending message to VMware." ]; then
        log "INFO: Not running on VMWare"
    else
        if [ "$rpctool_stderr" == "No value found" ]; then
            log "INFO: Not running on vSphere"
        else
            err "ERROR: Cannot get OVF parameters through VMware Tools. Exiting ..."
        fi
    fi
fi

# Convert OVF properties to bash variables
if [ -s /var/lib/cc-ovf/ovf.xml ]; then
    #Debugging
    printf "Debug info (ovf.xml):\n" 2>&1 | sed -e 's#^#   #'
    cat /var/lib/cc-ovf/ovf.xml 2>&1 | sed -e "s#^#     ${LINENO} #"

    getprops_from_ovfxml /var/lib/cc-ovf/ovf.xml > /var/lib/cc-ovf/ovf.vars
#    cp -vp /var/lib/cc-ovf/ovf.vars /var/lib/cc-ovf
else
    rm -f /var/lib/cc-ovf/ovf.vars
    touch /var/lib/cc-ovf/ovf.vars
fi

# Load environment variables from guestinfo or from '/ovf.env' on CD
haveENV=false
if [ ! -s /var/lib/cc-ovf/ovf.vars ]; then
    log "INFO: No environment presented by the platform. Look for it on the CD..."
    mkdir -p /mnt/ovf.cfg
    mount /dev/cdrom /mnt/ovf.cfg 2>&1 | sed -e 's#^#   #'
    if [ $? -ne 0 ]; then
        umount /dev/cdrom 2>&1 | sed -e 's#^#   #'
        log "WARN: No CD..."
    else
	if [ ! -r /mnt/ovf.cfg/ovf.env ]; then
            umount /dev/cdrom 2>&1 | sed -e 's#^#   #'
            log "WARN: No OVF environment on the CD..."
	else
	    printf "OVF environment (per cdrom/ovf.env):\n" 2>&1 | sed -e 's#^#   #'
	    cat /mnt/ovf.cfg/ovf.env 2>&1 | sed -e 's#^#     #'
	    . /mnt/ovf.cfg/ovf.env
	    haveENV=true
	    umount /dev/cdrom
	    log "Applying OVF customizations (from CD)..."
	fi
    fi
else
    vars_md5=$(md5sum -b /var/lib/cc-ovf/ovf.vars|awk '{print $1}')
    if [ -e /var/lib/cc-ovf/vars.md5 ]; then
	if [ "$(cat /var/lib/cc-ovf/vars.md5)" != "$vars_md5" ]; then
	    err "ERROR: changes to VMware properties not allowed! Exiting..."
	fi
    fi
    printf "$vars_md5\n" > /var/lib/cc-ovf/vars.md5

    printf "OVF environment (per VMware properties):\n" 2>&1 | sed -e 's#^#   #'
    cat /var/lib/cc-ovf/ovf.vars 2>&1 | sed -e 's#^#     #'
    . /var/lib/cc-ovf/ovf.vars
    haveENV=true
    log "Applying OVF customizations (per VMWare properties)..."
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

# Figure out which NIC is signalling
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
	    err "ERROR: Couldn't determine signalling NIC!"
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

# Load up network interface variables
declare -A mgmt
declare -A sig
declare -A mgmt6
declare -A sig6

# Load up IPv4 network interface variables
for k in fixed_address subnet_mask routers domain_name_servers ntp_servers domain_name domain_search host_name; do
    var=mgmt_${k}
    mgmt[${k}]=${!var}

    var=sig_${k}
    sig[${k}]=${!var}
done
mgmt[mac_address]=$(ip addr show dev ${mgmt_nic}|grep link/ether|awk '{print $2}')
sig[mac_address]=$(ip addr show dev ${sig_nic}|grep link/ether|awk '{print $2}')

# Load up IPv6 network interface variables
for k in fixed_address prefix_len routers domain_name_servers ntp_servers domain_search; do
    var=mgmt6_${k}
    mgmt6[${k}]=${!var}

    var=sig6_${k}
    sig6[${k}]=${!var}
done
mgmt6[mac_address]=$(ip addr show dev ${mgmt_nic}|grep link/ether|awk '{print $2}')
sig6[mac_address]=$(ip addr show dev ${sig_nic}|grep link/ether|awk '{print $2}')

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

# IPv4 self configuration
if [ $doIPv4 -ne 0 ]; then
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
  option subnet-mask ${eth[subnet_mask]};\n\
  option routers ${eth[routers]};\n\
  option domain-name-servers ${eth[domain_name_servers]};\n\
  option ntp-servers ${eth[ntp_servers]};\n\
  option domain-name \"${eth[domain_name]}\";\n\
  option domain-search \"${eth[domain_search]}\";\n\
  option host-name \"${eth[host_name]}\";\n\
  renew 4 2037/12/31 00:00:00;\n\
  rebind 4 2037/12/31 00:00:00;\n\
  expire 4 2037/12/31 00:00:00;\n\
}\n\
" > /var/lib/cc-ovf/${nic}-ipv4.lease
		    rm -vf /var/lib/dhcp/dhclient.leases 2>&1 | sed -e "s#^#   #"
		    for lease in $(find /var/lib/cc-ovf \( -name "${mgmt_nic}-ipv4.lease" -o -name "${sig_nic}-ipv4.lease" \)); do
			cat $lease >> /var/lib/dhcp/dhclient.leases
		    done
		    log "Retrying DHCP for ${nic} to pickup values from properties..."
		    dhclient -1 -v ${nic} >> /var/log/ovf-sc.dhclient-4.log 2>&1 
		fi
	    fi
	done

        # If after manufacturing leases from the environment we're still missing some,
        # call it quits, declare an error and wait for operator intervention.
	if [ "$(find /var/lib/cc-ovf \( -name "${mgmt_nic}-ipv4.lease" -o -name "${sig_nic}-ipv4.lease" \)|wc -l)" -ne ${#nics[@]} ]; then
		    err "ERROR: Can't determine network configuration!"
	fi

#    set +x
#    let "cmd_done=0"
#    while [ $cmd_done -eq 0 ]; do
#	let "prompt_done=0"
#	while [ $prompt_done -eq 0 ]; do
#	    doPrompt "Set management IP\nSpecify an IPv4 address for bond1" "" "$ip4_ADDRESS"
#	    chkIP $RESPONSE
#	    if [ "$chkIP_result" != "V4" ]; then
#		printf "[YOUR INPUT WAS NOT AN IPv4 ADDRESS]\n"
#	    else
#		let "prompt_done=1"
#	    fi
#	done
#	ip4_ADDRESS=$RESPONSE
#
#	doConfirm
#	cfrm=$?
#	if [ $cfrm -eq 1 ]; then
#	    printf "thanks\n"
#	    let "cmd_done=1"
#	fi
#	if [ $cfrm -eq 2 ]; then
#	    printf "cancelled\n"
#	    let "cmd_done=1"
#	fi
#    done
    fi   
fi

# IPv6 self configuration
if [ $doIPv6 -ne 0 ]; then
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
  option dhcp6.domain-search \"${eth[domain_search]}\";
		option dhcp6.sntp-servers ${eth[ntp_servers]};\n\
}\n\
" > /var/lib/cc-ovf/${nic}-ipv6.lease
		    rm -vf /var/lib/dhcp/dhclient6.leases 2>&1 | sed -e "s#^#   #"
		    for lease in $(find /var/lib/cc-ovf \( -name "${mgmt_nic}-ipv6.lease" -o -name "${sig_nic}-ipv6.lease" \)); do
			cat $lease >> /var/lib/dhcp/dhclient6.leases
		    done
		    cat /var/lib/dhcp/dhclient6.leases 2>&1 | sed -e "s#^#     ${LINENO} #"
		    log "Retrying DHCP6 for ${nic} to pickup values from properties..."
		    killall dhclient > /dev/null 2>&1
		    dhclient -6 -v -1 ${nic} >> /var/log/ovf-sc.dhclient-6.log 2>&1 
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
if [ "${mgmt_protocol^^}" == "IPV6" ]; then
    mgmt_ip=${mgmt_ip6}
fi
if [ ! -z "${mgmt_ip6}" ]; then
    if [ -z "${mgmt_ip4}" ]; then
	err "ERROR: Both IPv6 and IPv4 must be configured for management interface! Exiting..."
    fi
fi

sig_ip4=$( ip -4 addr show dev ${sig_nic}|grep global|sed -e 's#^.*inet* \([^/]*\)/.*$#\1#' )
sig_ip6=$( ip -6 addr show dev ${sig_nic}|grep global|sed -e 's#^.*inet6* \([^/]*\)/.*$#\1#' )
sig_ip=${sig_ip4}
if [ "${sig_protocol^^}" == "IPV6" ]; then
    sig_ip=${sig_ip6}
fi
if [ ! -z "${sig_ip6}" ]; then
    if [ -z "${sig_ip4}" ]; then
	err "ERROR: Both IPv6 and IPv4 must be configured for signaling interface! Exiting..."
    fi
fi

if [ -r /var/lib/cc-ovf/dhcp.${mgmt_nic}-ipv4.env ]; then
    . /var/lib/cc-ovf/dhcp.${mgmt_nic}-ipv4.env
fi
if [ -r /var/lib/cc-ovf/dhcp.${sig_nic}-ipv4.env ]; then
    . /var/lib/cc-ovf/dhcp.${sig_nic}-ipv4.env
fi

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
    log "INFO: Configuring signalling network namespace"

    echo ip netns add signalling 2>&1 | sed -e 's#^#   #'
    ip netns add signalling 2>&1 | sed -e 's#^#   #'
    echo ip link set ${sig_nic} netns signalling 2>&1 | sed -e 's#^#   #'
    ip link set ${sig_nic} netns signalling 2>&1 | sed -e 's#^#   #'
    ip netns exec signalling ifconfig lo up 2>&1 | sed -e 's#^#   #'
    echo ip netns exec signalling ifconfig lo up 2>&1 | sed -e 's#^#   #'
    ip netns exec signalling ifconfig ${sig_nic} ${sig_ip4} up 2>&1 | sed -e 's#^#   #'
    echo ip netns exec signalling route add default gateway $new_routers dev ${sig_nic} 2>&1 | sed -e 's#^#   #'
    if [ ! -z "${sig_ip6}" ]; then
	echo ip netns exec signalling ifconfig eth1 inet6 add ${sig_ip6}/${new_ip6_prefixlen} up 2>&1 | sed -e 's#^#   #'
	ip netns exec signalling ifconfig eth1 inet6 add ${sig_ip6}/${new_ip6_prefixlen} up 2>&1 | sed -e 's#^#   #'
    fi

    ip netns exec signalling route add default gateway $new_routers dev ${sig_nic} 2>&1 | sed -e 's#^#   #'
    mkdir -p /etc/netns/signalling
    if [ "${sig_protocol^^}" == "IPV6" ]; then
	printf "nameserver $new_dhcp6_name_servers\n" > /etc/netns/signalling/resolv.conf
    else
	printf "nameserver $new_domain_name_servers\n" > /etc/netns/signalling/resolv.conf
    fi
    printf "Debug info (signalling netns routing table):\n" 2>&1 | sed -e 's#^#   #'
    echo ip netns exec signalling route 2>&1 | sed -e "s#^#     ${LINENO} #"
    ip netns exec signalling route 2>&1 | sed -e "s#^#     ${LINENO} #"
    echo ip netns 2>&1 | sed -e 's#^#   #'
    ip netns 2>&1 | sed -e 's#^#   #'

    (
	. /var/lib/cc-ovf/dhcp.${mgmt_nic}-ipv4.env
	echo route add default gateway $new_routers dev ${mgmt_nic} 2>&1 | sed -e 's#^#   #'
	route add default gateway $new_routers dev ${mgmt_nic} 2>&1 | sed -e 's#^#   #'
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

echo dig google.com 2>&1 | sed -e "s#^#     ${LINENO} #"
dig google.com >&1 | sed -e "s#^#     ${LINENO} #"

# Function for substituting our variables into config files
declare -A vars
vars[signaling_ip]=${sig_ip}
vars[signalling_ip]=${sig_ip}
if [ "${ip_protocol^^}" == "IPV6/IPV4" ]; then
    vars[signaling_ip_qual]="[${sig_ip}]"
    vars[signalling_ip_qual]="[${sig_ip}]"
else
    vars[signaling_ip_qual]="${sig_ip}"
    vars[signalling_ip_qual]="${sig_ip}"
fi
vars[mgmt_ip]=${mgmt_ip}
vars[etcd_cluster]=${etcd_cluster}
vars[node_idx]=${node_idx}
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

# Check to see if Clearwater is install and if not don't do much.
# If Clearwater is installed then perform self-configuration per
# OVF properties or what we find on the CD.
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
        mount /dev/cdrom /mnt/ovf.cfg > /dev/null 2>&1
	if [ $? -eq 0 ]; then
	    if [ -d /mnt/ovf.cfg/payload ]; then
		cfg_dir="cdrom:/payload"
	    fi
	    umount /dev/cdrom > /dev/null 2>&1
	fi
    fi
    cc_dirs=(/etc/chronos /etc/cassandra /etc/clearwater)
    if [ ! -z $cfg_dir ]; then
	cfg_loc=( $(echo $cfg_dir|sed -e 's#:# #g'|sed -e 's#\r##g') )
	if [ "${#cfg_loc[@]}" != "2" ];then
            if [ "${#cfg_loc[@]}" != 1 ];then
		err "ERROR: Invalid format of 'cfg_dir' ($cfg_dir) property. Exiting ..."
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
            err "ERROR: Cannot mount ${cfg_dev}. Exiting ..."
	fi
	if [ ! -f /mnt/ovf.cfg/${cfg_loc} ]; then
            if [ ! -d /mnt/ovf.cfg/${cfg_loc} ]; then
		if [ ! -z "$cfg_dev" ]; then
                    umount ${cfg_dev} 2>&1 | sed -e 's#^#   #'
		fi
		err "ERROR: Invalid/missing config - ${cfg_loc}. Exiting ..."
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
		err "ERROR: Invalid tarball - ${cfg_loc}. Exiting ..."
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
        for file in ${subst_files[@]}; do
	    subst_vars "$file"
        done
        subst_files=($(find ${cc_dirs[@]} -type f -print0 2> /dev/null|xargs -0 grep -l "\$[[][^]]*[]]"))
        if [ "${#subst_files[@]}" -gt "0" ]; then
	    err "ERROR: Invalid substitutions found:" "$(find ${cc_dirs[@]} -type f -print0|xargs -0 grep -n "\$[[][^]]*[]]")"
        fi
    fi
fi

# We're done!
log "OVF customization complete!"

if [ -z "$UPSTART_JOB" ]; then
    # Pause for debugging
    askQuestion "Press <enter> to continue"
fi
exit 0
