#!/bin/bash


ME=`echo $0|tr '\\\\' '/'|sed -e 's#\([A-Za-z]\):#/\1#'`
MEDIR=`dirname ${ME}`
if [ "$MYDIR" == "" ];then
    MYDIR=`cd $MEDIR;pwd`
fi

if [ -z $1 ]; then
    cd $MYDIR
else
    cd $1
fi

printf "\"Menu\",\"Protection\",\"Action\",\"Description\"\n"
for cmd in `find . -follow \( -name '??-*.cmd' -o -name '??-*.bash' \)|sed -e 's#^[.]/##'`; do
    file=$cmd
    menu=`dirname $cmd|sed -e 's#/#=>#g'|sed -e 's#..-\([^=]*\)#\1#g'|sed -e 's#_# #g'`
    help=`grep '^#?' $file|sed -e 's/^#[?][ 	]*//'`
    prot=`grep '^#+' $file|sed -e 's/^#[+][ 	]*//'|sed -e 's#cc_read#R#g'|sed -e 's#cc_write#W#g'|sed -e 's#cc_admin#A#g'|sed -e 's#cc_create#C#g'|sed -e 's#cc_debug#D#g'`
    cmd=`basename $cmd|sed -e 's#..-\([^.]*\)[.].*#\1#g'|sed -e 's#_# #g'`
    printf "\"$menu\",\"$prot\",\"$cmd\",\"$help\"\n"
done|sort

printf "\nLegend: MONITOR=R; MAINTENANCE=R+W+C; ADMIN=R+W+C+A; DEBUG=R+W+C+A+D\n"
