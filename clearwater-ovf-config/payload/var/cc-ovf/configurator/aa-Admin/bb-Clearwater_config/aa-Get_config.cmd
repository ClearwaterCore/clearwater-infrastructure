#!/bin/bash
#? View the current settings
#+ cc_admin

ME=`echo $0|tr '\\\\' '/'|sed -e 's#\([A-Za-z]\):#/\1#'`
MEDIR=`dirname ${ME}`
MYDIR=`cd $MEDIR;pwd`

M80ENV=$1

. $M80ENV/.env $M80ENV

getSettings

printf "\
Variable         Value\n\
---------------- --------------------------\n\
etcd_cluster     ${etcd_cluster}\n\
node_idx         ${node_idx}\n\
local_site_name  ${local_site_name}\n\
remote_site_name ${remote_site_name}\n
"
