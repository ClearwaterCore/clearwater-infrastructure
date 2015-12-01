#!/bin/bash
#? Display this node's IP settings
#+ cc_admin

ME=`echo $0|tr '\\\\' '/'|sed -e 's#\([A-Za-z]\):#/\1#'`
MEDIR=`dirname ${ME}`
MYDIR=`cd $MEDIR;pwd`

M80ENV=$1

. $M80ENV/.env $M80ENV

getSettings

printf "IP Settings:\n\n"
(
    $MYDIR/cc-Configure_IP_setting/aa-Management/aa-Get_settings.cmd $M80ENV
    printf "\n"
    $MYDIR/cc-Configure_IP_setting/bb-Signaling/aa-Get_settings.cmd $M80ENV
) 2>&1 | sed -e 's#^#  #'

