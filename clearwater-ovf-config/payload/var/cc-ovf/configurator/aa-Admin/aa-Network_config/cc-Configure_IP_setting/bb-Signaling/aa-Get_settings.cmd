#!/bin/bash
#? View current signaling settings
#+ cc_admin

ME=`echo $0|tr '\\\\' '/'|sed -e 's#\([A-Za-z]\):#/\1#'`
MEDIR=`dirname ${ME}`
MYDIR=`cd $MEDIR;pwd`

M80ENV=$1

. $M80ENV/.env $M80ENV

getSettings

printf "\
Signaling variable  Value\n\
-------------------- --------------------------\n"
for var in fixed_address subnet_mask routers domain_name_servers; do
    mvar="sig_${var}"
    printf "\
%-20s %s\n" "${var}" "${!mvar}"
done

