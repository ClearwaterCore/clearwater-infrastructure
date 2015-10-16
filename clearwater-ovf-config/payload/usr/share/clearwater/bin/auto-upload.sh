#!/bin/bash

# Send stdout/stderr to a log file
exec >  >( stdbuf -i0 -o0 -e0 tee -a /var/log/auto-upload.log )
exec 2>&1

printf "$0 - START - $(date)\n"

. /etc/clearwater/config

printf "Environment:\n"
set|sort 2>&1 | sed -e 's#^#  #'

    # Are we in an etcd cluster?
if [ ! -z "$etcd_cluster" ]; then
    # Is etcd installed?
    if [ -e /etc/init.d/clearwater-etcd ]; then
	printf "clearwater-etcd is installed!\n"
	etcd_nodes=( $(echo ${etcd_cluster}|sed -e 's#,# #g') )
	found=0
	for etcd_node in ${etcd_nodes[@]}; do
	    if [ "${management_local_ip:-$local_ip}" == "${etcd_node}" ]; then
		found=1
		break
	    fi
	done

        # Are we a forming member of this cluster?
	if [ $found -ne 0 ]; then
	    printf "We are a founding member of the cluster!\n"
            printf "Wait for etcd to be ready..."
	    /usr/share/clearwater/bin/poll_etcd.sh > /dev/null 2>&1
	    while [ $? -ne 0 ]; do
		sleep 1
		printf "."
		/usr/share/clearwater/bin/poll_etcd.sh > /dev/null 2>&1
	    done
	    printf "ready!\n"

	    printf "clearwater-etcd is up @ $(date)\n"
	    clearwater-status

	    for upload_script in $(find /usr/share/clearwater/clearwater-config-manager/scripts -name 'upload_*' \! -name 'upload_json'); do
		echo curl -sL http://${management_local_ip:-$local_ip}:4000/v2/keys/clearwater/${local_site_name}/configuration/$(basename ${upload_script}|sed -e 's#^upload_##')\|grep -iq \"key not found\"
		if curl -sL http://${management_local_ip:-$local_ip}:4000/v2/keys/clearwater/${local_site_name}/configuration/$(basename ${upload_script}|sed -e 's#^upload_##')|grep -iq "key not found" > /dev/null 2>&1; then
		    printf "Running ${upload_script}:\n"
		    echo ${upload_script} 2>&1 | sed -e 's##\n#g' | sed -e 's#^#  #'
		    ${upload_script} 2>&1 | sed -e 's##\n#g' | sed -e 's#^#  #'
		fi
	    done
	fi
    fi
fi

printf "$0 - END - $(date)\n"
