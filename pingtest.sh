#!/bin/bash
 
#=====================================================================
# pingtest.sh, v1
# Released to public domain
# (1) Attempts to ping external targets to test connectivity.
# (2) If all pings fail, resets interface and retries pings.
# (3) If pings fail again following reset, reboots pfSense.
#=====================================================================
 
#=====================================================================
# USER SETTINGS
#
# Set ping targets
HOST1=1.1.1.1
HOST2=8.8.8.8
 
# Interface to reset, usually your WAN
INTERFACE=wan
 
# Log file
LOGFILE=/root/pingtest.log
ENABLELOGGING=true

#=====================================================================

log_message() {
    if [ "$ENABLELOGGING" = true ]; then
        echo "$1" | tee -a "$LOGFILE"
    else
        echo "$1"
    fi
}

# Function to ping hosts
ping_hosts() {
    local counting
    counting=$(ping -o -s 0 -c 10 -W 1 $HOST1 | grep 'received' | awk -F',' '{ print $2 }' | awk '{ print $1 }')

    # If ping to $HOST1 fails, try $HOST2
    if [ "${counting:-0}" -eq 0 ]; then
        counting=$(ping -o -s 0 -c 10 -W 1 "$HOST2" | grep 'received' | awk -F',' '{ print $2 }' | awk '{ print $1 }')
    fi

    echo $counting
}

# Function to reset interface
attempt_reset() {
    local INTERFACE=$1
    local RESET_STATUS=0
 
    # soft reload of interface
    RESET_OUTPUT=$(/usr/local/sbin/pfSctl -c "interface reload $INTERFACE")
 
    if echo "$RESET_OUTPUT" | grep -q "OK"; then
        RESET_STATUS=1
    else
        # If dhclient fails, log the error
        log_message "$(date +'%d/%m/%y - %H:%M:%S') Failed to reset interface $INTERFACE. Response: $RESET_OUTPUT"
    fi

    # attempt pings again
    counting=$(ping_hosts)
 
    # If both pings fail
    if [ "${counting:-0}" -eq 0 ]; then
        # yanks interface and brings it up fresh
        php -r "require_once('/etc/inc/interfaces.inc'); interface_bring_down('$INTERFACE'); interface_configure('$INTERFACE');"
 
        if [ $? -ne 0 ]; then
            # If PHP fails to reset the interface, log the error
            log_message "$(date +'%d/%m/%y - %H:%M:%S') Failed to reset interface $INTERFACE"
        else
            RESET_STATUS=1
        fi
    fi
    echo $RESET_STATUS
}

# Rotate the log if it's over 500KB
[ -s "$LOGFILE" ] && [ "$(wc -c <"$LOGFILE")" -gt 500000 ] && > "$LOGFILE"
 
# Testing uptime to run script only xx seconds after boot
 
# Current time
currtime=$(date +%s)
 
# Get boot time from sysctl output (extract 'sec = ####' value)
boottime=$(sysctl -n kern.boottime | sed 's/.*sec = \([0-9]*\),.*/\1/')
 
# Calculate uptime
utime=$((currtime - boottime))
 
# If boot is longer than 120 seconds ago... (To avoid bootloops)
if [ $utime -gt 120 ]; then
 
    log_message "Testing Connection at $(date +'%d/%m/%y - %H:%M:%S') uptime: $utime seconds"
 
    # Attempt to ping the hosts
    counting=$(ping_hosts)
 
    # If pings fail
    if [ "${counting:-0}" -eq 0 ]; then
        ENABLELOGGING=true
        log_message "$(date +'%d/%m/%y - %H:%M:%S') All pings failed. Resetting interface $INTERFACE."
 
        # Attempt to reset interface
        RESET_STATUS=$(attempt_reset "$INTERFACE")
 
        if [ $RESET_STATUS -eq 0 ]; then
            log_message "$(date +'%d/%m/%y - %H:%M:%S') Resetting interface failed. Rebooting..."
 
            /etc/rc.backup_rrd.sh
            reboot
        else
            sleep 5  # Adding a delay to ensure the interface resets
 
            # Retest after NIC reset
            counting=$(ping_hosts)
 
            if [ "${counting:-0}" -eq 0 ]; then
                # Network down
                # Save RRD data
                log_message "$(date +'%d/%m/%y - %H:%M:%S') All pings failed. Rebooting..."
 
                /etc/rc.backup_rrd.sh
                reboot
            else
                log_message "$(date +'%d/%m/%y - %H:%M:%S') Interface reset successful, pings successful."
            fi
        fi
    else
        # Network up
        log_message "$(date +'%d/%m/%y - %H:%M:%S') Network is up. Pings successful."
    fi
fi
