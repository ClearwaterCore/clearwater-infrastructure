#!/bin/bash
#? Set the node index
#+ cc_admin

ME=`echo $0|tr '\\\\' '/'|sed -e 's#\([A-Za-z]\):#/\1#'`
MEDIR=`dirname ${ME}`
MYDIR=`cd $MEDIR;pwd`

M80ENV=$1

. $M80ENV/.env $M80ENV

getSettings

new_VALUE=${node_idx}

let "cmd_done=0"
while [ $cmd_done -eq 0 ]; do
    let "prompt_done=0"
    while [ $prompt_done -eq 0 ]; do
	doPrompt "Set the node index\nSpecify the new node_idx" "" "$new_VALUE"
	let "idx=$RESPONSE"
	if [ $idx -lt 1 ]; then
  	    printf "\n[A NODE INDEX MUST BE GREATER THAN ONE]\n"
	else
	    let "prompt_done=1"
	fi
    done
    new_VALUE=`printf "$RESPONSE"|sed -e 's#[  ]?# #g'|sed -e 's#[ ]*$##g'`

    doConfirm
    cfrm=$?
    if [ $cfrm -eq 1 ]; then
	sed -ie '/^node_idx=/d' /var/lib/cc-ovf/configurator.wip; rm -f /var/lib/cc-ovf/configurator.wipe
	printf "node_idx=\"${new_VALUE}\"\n" >> /var/lib/cc-ovf/configurator.wip
	let "cmd_done=1"
    fi

    if [ $cfrm -eq 2 ]; then
	exit -1
    fi
done
