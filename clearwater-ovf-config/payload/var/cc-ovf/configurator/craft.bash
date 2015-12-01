#!/bin/bash

if [ "$BATCHPATH" != "" ]; then
    # We came from the batch file so make some adjustments for the
    # MinGw stuff.
    export "BATCHPATH=`echo $BATCHPATH|sed -e 's#\\\\#/#g'|sed -e 's#^\\([a-zA-Z]\\):#/\\1#'`"
else
    ME=`echo $0|tr '\\\\' '/'|sed -e 's#\([A-Za-z]\):#/\1#'`
    MEDIR=`dirname ${ME}`
    BATCHPATH=`cd $MEDIR;pwd`
fi

bash $BATCHPATH/.m80 "$@"
