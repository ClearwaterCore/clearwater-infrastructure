#!/bin/bash
# @file cc-auto-install-nodes.sh
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

# Send stdout/stderr to a log file
exec >  >( stdbuf -i0 -o0 -e0 tee /var/log/cc-auto-install-nodes.log )
exec 2>&1

set +e

# Function for logging to syslog
log() {
    echo "   $*"
    logger "self-config:" "$*"
}

# Function to emit error message and wait for user input
err() {
    printf "\
!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!\n\
!!\n\
!! $*\n\
!!\n\
!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!\n\
"
    logger "self-config:" "$*"
    printf "Press <Enter> to continue booting..."
    read RESPONSE

    # Close stdout to flush to the log
    exec 1>&-
    exit 1
}

if [ -r /var/cc-ovf/cc-auto-install-nodes ]; then
    /var/cc-ovf/bin/setup
    apt-get update
    first=1
    node_types=$(cat /var/cc-ovf/cc-auto-install-nodes)
    for node_type in $node_types; do
        if [[ "${node_type}" =~ (homestead|ralf|sprout) ]]; then
            ccVersion=$(cd /var/cc-ovf/binary; find . -name "metaswitch-core-${node_type}_*_all.install"|tail -1|sed -e 's#^[^_]*_\([^_]*\)_all.install$#\1#')
            if [ ! -x /etc/init.d/${node_type} ]; then
                if [ $first -ne 0 ]; then
                    if [ 0 -eq 1 ]; then
                        printf "\n\
***************************************************************************\n\
***************************************************************************\n\
***************************************************************************\n\
\n\
Ready to install Clearwater Core ($ccVersion) ${node_types} software.\n\
"
                        printf "Press <enter> to continue..."
                        read RESPONSE
                    fi
                fi
                first=0
                printf "\n\
***************************************************************************\n\
***************************************************************************\n\
***************************************************************************\n\
\n\
Installing Clearwater Core ($ccVersion) ${node_type} software:\n\
"
                echo /var/cc-ovf/bin/install ${node_type} 2>&1 | sed -e 's#^#  #'
                printf "  ";for i in {1..5}; do (sleep 1;printf ".");done;printf "\n"
                (/var/cc-ovf/bin/install ${node_type}; echo $? > /tmp/${node_type}.sta) 2>&1 | stdbuf -i0 -o0 -e0 sed -e 's#^#  #'
                sta=$(cat /tmp/${node_type}.sta)
                if [ $sta -ne 0 ]; then
                    err "ERROR: Installation of ${node_type} failed! Halting ..."
                    # Close stdout to flush to the log
                    exec 1>&-
                    exit 1
                fi
            fi
        else
            version=$(cd /var/extras/binary; find . -name "${node_type}_*_amd64.deb"|tail -1|sed -e 's#^[^_]*_\([^_]*\)_amd64.deb$#\1#')
            if [ ! -z ${version} ]; then
                if [ ! -x /etc/init.d/${node_type} ]; then
                    if [ $first -ne 0 ]; then
                        if [ 0 -eq 1 ]; then
                            printf "\n\
***************************************************************************\n\
***************************************************************************\n\
***************************************************************************\n\
\n\
Ready to install ${node_type}=${version}.\n\
"
                            printf "Press <enter> to continue..."
                            read RESPONSE
                        fi
                    fi
                    first=0
                    printf "\n\
***************************************************************************\n\
***************************************************************************\n\
***************************************************************************\n\
\n\
Installing ${node_type}=${version}:\n\
"
                    echo apt-get install ${node_type}=${version} 2>&1 | sed -e 's#^#  #'
                    printf "  ";for i in {1..5}; do (sleep 1;printf ".");done;printf "\n"
                    (apt-get -y -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" install --force-yes ${node_type}=${version}; echo $? > /tmp/${node_type}.sta) 2>&1 | stdbuf -i0 -o0 -e0 sed -e 's#^#  #'
                    sta=$(cat /tmp/${node_type}.sta)
                    if [ $sta -ne 0 ]; then
                        err "ERROR: Installation of ${node_type} failed! Halting ..."
                        # Close stdout to flush to the log
                        exec 1>&-
                        exit 1
                    fi
                fi
            fi
        fi
    done

    if [ -d /var/extras/licensing ]; then
        if [ -x /var/extras/licensing/inst ]; then
            printf "\n\
***************************************************************************\n\
***************************************************************************\n\
***************************************************************************\n\
\n\
Installing licensing support:\n\
"
            echo /var/extras/licensing/inst 2>&1 | sed -e 's#^#  #'
            /var/extras/licensing/inst 2>&1 | sed -e 's#^#  #'
        fi
    fi

    cp -vp /etc/apt/sources.list.bak /etc/apt/sources.list 2>&1 | sed -e 's#^#  #'

    mv -v /var/cc-ovf/cc-auto-install-nodes /var/cc-ovf/cc-auto-install-nodes.orig 2>&1 | sed -e 's#^#  #'

    monit stop all 2>&1 | sed -e 's#^#  #'

    rm -vfr /var/lib/clearwater-etcd/* /var/lib/monit/* 2>&1 | sed -e 's#^#  #'

    printf "\n\
***************************************************************************\n\
***************************************************************************\n\
***************************************************************************\n\
\n\
Limiting the size of logs and dumps directory:\n\
"
    /usr/bin/clearwater-limitdir /var/clearwater-diags-monitor/dumps -l 5G -y 2>&1 | sed -e 's#^#  #'
    /usr/bin/clearwater-limitdir /var/log -l 2G -y 2>&1 | sed -e 's#^#  #'

    if [ $first -eq 0 ]; then
        printf "\n\
***************************************************************************\n\
***************************************************************************\n\
***************************************************************************\n\
\n\
Finishing ${node_types} install."
        for i in {1..10}; do (sleep 1;sync;printf ".");done
        printf "Done.\n"
        printf "\nYou can either power down the machine now OR\nPress <enter> to reboot and continue configuration..."
        read RESPONSE
        rm -f /boot/grub/grubenv
        printf "\nRebooting."
        for i in {1..5}; do (sleep 1;sync;printf ".");done
        reboot -f
    fi
fi

# Close stdout to flush to the log
exec 1>&-
exit 0
