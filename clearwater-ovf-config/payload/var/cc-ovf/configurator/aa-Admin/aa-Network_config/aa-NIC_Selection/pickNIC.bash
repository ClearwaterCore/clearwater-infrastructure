#!/bin/bash
ME=`echo $0|tr '\\\\' '/'|sed -e 's#\([A-Za-z]\):#/\1#'`
MEDIR=`dirname ${ME}`
MYDIR=`cd $MEDIR;pwd`

M80ENV=$1

. $M80ENV/.env $M80ENV

if [ "$(ip netns list)" = "signaling" ]; then 
    num_nics=$((ip addr show; ip netns exec signaling ip addr show)|grep "eth[0-9]:"|wc -l)
else
    num_nics=$(ip addr show|grep "eth[0-9]:"|wc -l)
fi
nic_var=$2
if [ -s /var/lib/cc-ovf/configurator.vars ]; then
    . /var/lib/cc-ovf/configurator.vars
fi
if [ -s /var/lib/cc-ovf/configurator.wip ]; then
    . /var/lib/cc-ovf/configurator.wip
fi
cur_nic_mac=${!nic_var}

let "cmd_done=0"
while [ $cmd_done -eq 0 ]; do
    printf "\nThe following NICs are available:\n\n"
    printf "\
         Interface MAC address\n\
         --------- -----------------\n\
"
    OIFS=$IFS
    IFS=
    let "i=0"
    while [ $i -lt $num_nics ]; do
	nic_mac=$((ip addr show dev eth$i; ip netns exec signaling ip addr show dev eth$i) 2>&1|grep link/ether|awk '{print $2}')
	if [ "${nic_mac}" == "${cur_nic_mac}" ]; then
	    printf "*"
	else
	    printf " "
	fi
	printf "  %2d    %-9s %s\n" "$i" $(printf "eth$i") "$nic_mac"
	let "i=$i + 1"
    done
    IFS=$OIFS
    printf "\nSelect NIC to be used for signaling: "
    read RESPONSE
    RESPONSE=`echo "$RESPONSE"|sed -e 's#[ 	]*##g'|sed -e 's#[^0-9]##g'`
    if [ "$RESPONSE" == "" ]; then
	exit -1
    fi
    let "nic_no=$RESPONSE"
    if ( (( $nic_no < 0 )) || (( $nic_no >= $num_nics )) ); then
	printf "[YOUR INPUT WAS NOT UNDERSTOOD]\n"
    else
	doConfirm 2
	cfrm=$?
	if [ $cfrm -eq 1 ]; then
	    nic_mac=$((ip addr show dev eth${nic_no};ip netns exec signaling ip addr show dev eth${nic_no}) 2>&1|grep link/ether|awk '{print $2}')
	    sed -ie "/^${nic_var}=/d" /var/lib/cc-ovf/configurator.wip; rm -f /var/lib/cc-ovf/configurator.wipe
	    printf "${nic_var}=\"${nic_mac}\"\n" >> /var/lib/cc-ovf/configurator.wip
	fi
	if [ $cfrm -eq 2 ]; then
	    exit -1
	fi
	let "cmd_done=1"
    fi
done
