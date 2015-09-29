#!/bin/bash
#? Set the etcd cluster IPs
#+ cc_admin

ME=`echo $0|tr '\\\\' '/'|sed -e 's#\([A-Za-z]\):#/\1#'`
MEDIR=`dirname ${ME}`
MYDIR=`cd $MEDIR;pwd`

M80ENV=$1

. $M80ENV/.env $M80ENV

getSettings

new_VALUE=${etcd_cluster}

let "cmd_done=0"
while [ $cmd_done -eq 0 ]; do
    let "prompt_done=0"
    while [ $prompt_done -eq 0 ]; do
	doPrompt "Set the etcd cluster IPs\nSpecify the new set of etcd cluster IPs" "" "$new_VALUE"
	let "prompt_done=1"
	etcd_nodes=$(echo ${RESPONSE}|sed -e 's#,# #g')
	for etcd_node in ${etcd_nodes[@]}; do
	    chkIP ${etcd_node}
	    if [ "$chkIP_result" != "V4" ]; then
  		printf "\n[YOUR INPUT WAS NOT A LIST IPv4 ADDRESSES]\n"
		let "prompt_done=0"
		break
	    fi
	done
	RESPONSE=$(printf "${etcd_nodes[*]}"|sed -e 's#[  ]?# #g'|sed -e 's#[ ]*$##g'|sed -e 's# #,#g')
    done
    new_VALUE=`printf "$RESPONSE"|sed -e 's#[  ]?# #g'|sed -e 's#[ ]*$##g'`

    doConfirm
    cfrm=$?
    if [ $cfrm -eq 1 ]; then
	sed -ie '/^etcd_cluster=/d' /var/lib/cc-ovf/configurator.wip; rm -f /var/lib/cc-ovf/configurator.wipe
	printf "etcd_cluster=\"${new_VALUE}\"\n" >> /var/lib/cc-ovf/configurator.wip
	let "cmd_done=1"
    fi

    if [ $cfrm -eq 2 ]; then
	exit -1
    fi
done
