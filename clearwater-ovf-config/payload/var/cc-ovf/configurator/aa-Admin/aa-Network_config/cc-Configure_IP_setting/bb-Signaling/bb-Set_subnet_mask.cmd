#!/bin/bash
#? Set the subnet-mask for the signaling interface
#+ cc_admin

ME=`echo $0|tr '\\\\' '/'|sed -e 's#\([A-Za-z]\):#/\1#'`
MEDIR=`dirname ${ME}`
MYDIR=`cd $MEDIR;pwd`

M80ENV=$1

. $M80ENV/.env $M80ENV

getSettings

new_VALUE=${sig_subnet_mask}

let "cmd_done=0"
while [ $cmd_done -eq 0 ]; do
    let "prompt_done=0"
    while [ $prompt_done -eq 0 ]; do
	doPrompt "Set the subnet-mask for the signaling interface\nSpecify the new subnet mask" "" "$new_VALUE"
	let "prompt_done=1"
	nodes=($(echo ${RESPONSE}|sed -e 's#,# #g'))
	if [ ${#nodes[@]} -ne 1 ]; then
  	    printf "\n[YOUR INPUT WAS NOT UNDERSTOOD]\n"
	    let "prompt_done=0"
	    continue
	fi
	for node in ${nodes[@]}; do
	    chkIP ${node}
	    if [ "$chkIP_result" != "V4" ]; then
  		printf "\n[YOUR INPUT WAS NOT A VALID SUBNET MASK]\n"
		let "prompt_done=0"
		break
	    fi
	done
	RESPONSE=$(printf "${nodes[*]}"|sed -e 's#[  ]?# #g'|sed -e 's#[ ]*$##g'|sed -e 's# #,#g')
    done
    new_VALUE=`printf "$RESPONSE"|sed -e 's#[  ]?# #g'|sed -e 's#[ ]*$##g'`

    doConfirm
    cfrm=$?
    if [ $cfrm -eq 1 ]; then
	sed -ie '/^sig_subnet_mask=/d' /var/lib/cc-ovf/configurator.wip; rm -f /var/lib/cc-ovf/configurator.wipe
	printf "sig_subnet_mask=\"${new_VALUE}\"\n" >> /var/lib/cc-ovf/configurator.wip
	let "cmd_done=1"
    fi

    if [ $cfrm -eq 2 ]; then
	exit -1
    fi
done
