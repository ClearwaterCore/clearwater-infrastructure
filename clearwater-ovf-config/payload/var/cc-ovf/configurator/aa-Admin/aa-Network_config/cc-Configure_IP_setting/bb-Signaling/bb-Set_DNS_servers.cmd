#!/bin/bash
#? Set the DNS(s) for the signaling interface
#+ cc_admin

ME=`echo $0|tr '\\\\' '/'|sed -e 's#\([A-Za-z]\):#/\1#'`
MEDIR=`dirname ${ME}`
MYDIR=`cd $MEDIR;pwd`

M80ENV=$1

. $M80ENV/.env $M80ENV

getSettings

new_VALUE=${sig_domain_name_servers}

let "cmd_done=0"
while [ $cmd_done -eq 0 ]; do
    let "prompt_done=0"
    while [ $prompt_done -eq 0 ]; do
	doPrompt "Set the DNS(s) for the signaling interface\nSpecify the new set of DNS servers" "" "$new_VALUE"
	let "prompt_done=1"
	nodes=($(echo ${RESPONSE}|sed -e 's#,# #g'))
	if [ ${#nodes[@]} -eq 0 ]; then
  	    printf "\n[YOU MUST SPECIFY AT LEAST ONE ADDRESS]\n"
	    let "prompt_done=0"
	    continue
	fi
	for node in ${nodes[@]}; do
	    chkIP ${node}
	    if [ "$chkIP_result" != "V4" ]; then
  		printf "\n[YOUR INPUT WAS NOT A LIST IPv4 ADDRESSES]\n"
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
	sed -ie '/^sig_domain_name_servers=/d' /var/lib/cc-ovf/configurator.wip; rm -f /var/lib/cc-ovf/configurator.wipe
	printf "sig_domain_name_servers=\"${new_VALUE}\"\n" >> /var/lib/cc-ovf/configurator.wip
	let "cmd_done=1"
    fi

    if [ $cfrm -eq 2 ]; then
	exit -1
    fi
done
