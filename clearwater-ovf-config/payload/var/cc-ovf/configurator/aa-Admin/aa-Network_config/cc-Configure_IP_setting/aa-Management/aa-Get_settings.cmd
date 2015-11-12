#!/bin/bash
#? View current management settings
#+ cc_admin

ME=`echo $0|tr '\\\\' '/'|sed -e 's#\([A-Za-z]\):#/\1#'`
MEDIR=`dirname ${ME}`
MYDIR=`cd $MEDIR;pwd`

M80ENV=$1

. $M80ENV/.env $M80ENV

getSettings

printf "\
Management variable  Value\n\
-------------------- --------------------------\n"
for var in fixed_address subnet_mask routers domain_name_servers ntp_servers domain_name domain_search host_name; do
    mvar="mgmt_${var}"
    printf "\
%-20s %s\n" "${var}" "${!mvar}"
done

