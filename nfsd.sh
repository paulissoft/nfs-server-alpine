#!/bin/bash

stop()
{
  # We're here because we've seen SIGTERM, likely via a Docker stop command or similar
  # Let's shutdown cleanly
  echo "SIGTERM caught, terminating NFS process(es)..."
  /usr/sbin/exportfs -uav
  /usr/sbin/rpc.nfsd 0
  pid1=`pidof rpc.nfsd`
  pid2=`pidof rpc.mountd`
  # For IPv6 bug:
  pid3=`pidof rpcbind`
  kill -TERM $pid1 $pid2 $pid3 > /dev/null 2>&1
  echo "Terminated."
  exit
}

add_line_to_etc_exports()
{
    # declare read-only variables
    declare -r fsid=$1
    declare -r dir=$2
    
    echo "Writing ${dir} to /etc/exports file"
    echo "${dir} ${PERMITTED}(${READ_ONLY},${SYNC},no_subtree_check,no_auth_nlm,insecure,no_root_squash,fsid=${fsid})" >> /etc/exports
}

create_etc_exports()
{
    # set error checking on
    set -e
    
    test ! -f /etc/exports || rm /etc/exports

    # Check if the PERMITTED variable is empty
    if [ -z "${PERMITTED}" ]; then
        echo "The PERMITTED environment variable is unset or null, defaulting to '*'."
        echo "This means any client can mount."
        PERMITTED='*'
    else
        echo "The PERMITTED environment variable is set."
        echo "The permitted clients are: ${PERMITTED}."
    fi

    # Check if the READ_ONLY variable is set (rather than a null string) using parameter expansion
    if [ -z ${READ_ONLY+y} ]; then
        echo "The READ_ONLY environment variable is unset or null, defaulting to 'rw'."
        echo "Clients have read/write access."
        READ_ONLY=rw
    else
        echo "The READ_ONLY environment variable is set."
        echo "Clients will have read-only access."
        READ_ONLY=ro
    fi

    # Check if the SYNC variable is set (rather than a null string) using parameter expansion
    if [ -z "${SYNC+y}" ]; then
        echo "The SYNC environment variable is unset or null, defaulting to 'async' mode".
        echo "Writes will not be immediately written to disk."
        SYNC=async
    else
        echo "The SYNC environment variable is set, using 'sync' mode".
        echo "Writes will be immediately written to disk."
        SYNC=sync
    fi
    
    # Check if the SHARED_DIRECTORY variable is empty
    if [ -z "${SHARED_DIRECTORY}" ]; then
        echo "The SHARED_DIRECTORY environment variable is unset or null, exiting..."
        exit 1
    elif [ ! -d "${SHARED_DIRECTORY}" ]; then
        echo "The directory '${SHARED_DIRECTORY}' does not exist, exiting..."
        exit 1
    fi

    # Add root directory ${SHARED_DIRECTORY} and its subfolders to the /etc/exports
    
    declare fsid=0
    
    add_line_to_etc_exports $fsid ${SHARED_DIRECTORY}

    # Backwards compability with https://github.com/sjiveson/nfs-server-alpine
    
    if [ -n "${SHARED_DIRECTORY_2}" ]; then
        set -- ${SHARED_DIRECTORY_2}
    else
        # get all files/folders in ${SHARED_DIRECTORY} and filter later
        set -- $(ls -1 ${SHARED_DIRECTORY})
    fi    

    for dir in 
    do
        case $dir in
            # absolute path?
            /*) ;;
            *) dir=${SHARED_DIRECTORY}/$dir;;
        esac
        if [ -d "$dir" ]
        then
            fsid=$(expr $fsid + 1)
            add_line_to_etc_exports $fsid "$dir"
        fi
    done

    # set error checking off
    set +e
}

create_etc_hosts_allow()
{
    # set error checking on
    set -ex

    if [ -f /etc/hosts.allow.txt ]
    then
        test ! -f /etc/hosts.allow || rm /etc/hosts.allow

        export PERMITTED

        if [ "$PERMITTED" = '*' ]
        then
            # inet addr:172.17.0.2  Bcast:172.17.255.255  Mask:255.255.0.0
            line=$(ifconfig eth0 | grep inet)
            subnet=$(echo $line | sed -e 's/.*Bcast://g' -e 's/Mask:.*//g' -e 's/255/0/g')
            mask=$(echo $line | sed -e 's/.*Mask://g')
            # strip spaces
            PERMITTED=$(echo "$subnet/$mask" | sed -e 's/ //g')
        fi
        
        envsubst < /etc/hosts.allow.txt > /etc/hosts.allow
    fi    

    # set error checking off
    set +ex
}

run()
{
    # Partially set 'unofficial Bash Strict Mode' as described here: http://redsymbol.net/articles/unofficial-bash-strict-mode/
    # We don't set -e because the pidof command returns an exit code of 1 when the specified process is not found
    # We expect this at times and don't want the script to be terminated when it occurs
    set -uo pipefail
    IFS=$'\n\t'

    # This loop runs till until we've started up successfully
    while true; do

        # Check if NFS is running by recording it's PID (if it's not running $pid will be null):
        pid=`pidof rpc.mountd`

        # If $pid is null, do this to start or restart NFS:
        while [ -z "$pid" ]; do
            for f in /etc/exports /etc/hosts.allow /etc/hosts.deny; do
                echo "Displaying $f contents:"
                cat $f
                echo ""
            done

            # Normally only required if v3 will be used
            # But currently enabled to overcome an NFS bug around opening an IPv6 socket
            echo "Starting rpcbind..."
            /sbin/rpcbind -w
            echo "Displaying rpcbind status..."
            /sbin/rpcinfo

            # Only required if v3 will be used
            # /usr/sbin/rpc.idmapd
            # /usr/sbin/rpc.gssd -v
            # /usr/sbin/rpc.statd

            echo "Starting NFS in the background..."
            /usr/sbin/rpc.nfsd --debug 8 --no-udp --no-nfs-version 2 --no-nfs-version 3
            echo "Exporting File System..."
            if /usr/sbin/exportfs -rv; then
                /usr/sbin/exportfs
            else
                echo "Export validation failed, exiting..."
                exit 1
            fi
            echo "Starting Mountd in the background..."These
            /usr/sbin/rpc.mountd --debug all --no-udp --no-nfs-version 2 --no-nfs-version 3
            # --exports-file /etc/exports

            # Check if NFS is now running by recording it's PID (if it's not running $pid will be null):
            pid=`pidof rpc.mountd`

            # If $pid is null, startup failed; log the fact and sleep for 2s
            # We'll then automatically loop through and try again
            if [ -z "$pid" ]; then
                echo "Startup of NFS failed, sleeping for 2s, then retrying..."
                sleep 2
            fi

        done

        # Break this outer loop once we've started up successfully
        # Otherwise, we'll silently restart and Docker won't know
        echo "Startup successful."
        break

    done

    while true; do

        # Check if NFS is STILL running by recording it's PID (if it's not running $pid will be null):
        pid=`pidof rpc.mountd`
        # If it is not, lets kill our PID1 process (this script) by breaking out of this while loop:
        # This ensures Docker observes the failure and handles it as necessary
        if [ -z "$pid" ]; then
            echo "NFS has failed, exiting, so Docker can restart the container..."
            break
        fi

        # If it is, give the CPU a rest
        sleep 1

    done
}

# -----------
# Main starts
# -----------

# Make sure we react to these signals by running stop() when we see them - for clean shutdown
# And then exiting
trap "stop; exit 0;" SIGTERM SIGINT

for f in /etc/exports /etc/hosts.allow; do
    if [ -r $f -a ! -w $f ]
    then
        echo "A read-only $f exists so will not overwrite that one"
    else
        case $f in
            /etc/exports) create_etc_exports;;
            /etc/hosts.allow) create_etc_hosts_allow;;
            *) echo "Programming error: $f"; exit 1;;
        esac
    fi
done

run

sleep 1
exit 1
