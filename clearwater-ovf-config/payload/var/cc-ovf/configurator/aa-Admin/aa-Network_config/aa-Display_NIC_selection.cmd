#!/bin/bash
#? Display mgmt/sig traffic NIC selection
#+ cc_admin

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

getSettings

printf "\
Type Interface MAC address\n\
---- --------- -----------------\n\
"
for type in mgmt sig; do
    if [ "${type}" == "mgmt" ]; then
	cur_nic_mac=$mgmt_mac_address
    else
	cur_nic_mac=$sig_mac_address
    fi
    let "i=0"
    while [ $i -lt $num_nics ]; do
	nic_mac=$((ip addr show dev eth$i; ip netns exec signaling ip addr show dev eth$i) 2>&1|grep link/ether|awk '{print $2}')
	if [ "${nic_mac}" == "${cur_nic_mac}" ]; then
	    printf "%-4s %-9s %s\n" "${type}" $(printf "eth$i") "$nic_mac"
	fi
	let "i=$i + 1"
    done
done
