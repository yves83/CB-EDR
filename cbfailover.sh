#!/bin/bash

#Monitoring Logic Flow
# Is Gateway Reachable?
# |- Yes
# |  Is Partition Mountted?
# |  |-- Yes
# |  |   |-- Is Lock file keep updating in 90 seconds by remote host?
# |  |       |-- Keep updating
# |  |       |   |-- Kill current nodes services & unmount the partition
# |  |       |-- Not updating
# |  |           |-- Start Carbon Black
# |  |-- No 
# |      |-- Is Remote Reachable?
# |          |-- Yes
# |          |   |-- Is Remote Service Running?
# |          |       |-- Up
# |          |       |   |-- Ignore
# |          |       |-- Down
# |          |           |-- Mount partition
# |          |               |-- Mount Success
# |          |               |   |-- Write log file
# |          |               |--- Mount Failure
# |          |                   |-- Write log file & trigger error
# |          |-- No
# |              |-- Mount partition
# |                  |-- Mount Success
# |                  |   |--Write log file
# |                  |-- Mount Failure
# |                      |--Write log file & trigger error
# |- No
#    Is partition mounted?
#    |-- Yes
#        |-- Kill the service
#        |-- Umount partition
#    |-- No
#        |-- Kill the service
# 

###################
# Variables
###################
VIRTUAL_IP=192.168.200.46
MON_TARGET=192.168.200.1
LOCK_FILE=/var/cb/cb-failover.lock

# Check LOCK_FILE last modify duration in minutes
LAST_DURATION=2

#Cronjob file
CB_CRONJOB=/etc/cron.d/cb

PART_MOUNT_STATE=1 # Expected Partition Count 1 or 3
PART_DATA=/var/cb
PART_LOG=/var/log/cb

VAR_VIP_FOUND=0 	# Indicate $VIRTUAL_IP found in current node
VAR_NETWORK_STATUS=0	# Indicate Can ping to $MON_TARGET
VAR_MOUNT_STATUS=0	# Indicate mount point status
VAR_LOCK_VALID=0	# Indicate Lock file is still valid. Need to wait 90 until it becomes invalid
VAR_LOCK_EXIST=0	# Indicate Lock file exist or NOT
VAR_LOCK_BY_LOCAL=0	# Indicate Lock file create by local or remote
VAR_SVC_STATUS=0	# Indicate the service status, higher than 0 indicates the failed service

CONSOLE_OUT=


###################
# Functions 
###################
# Write to Console
function FlushConsole() {
   echo $CONSOLE_OUT
   CONSOLE_OUT=""
}

function WriteConsole() {
   CONSOLE_OUT="$CONSOLE_OUT $1" 
}

# Handle Cb Cron Job file
function CbCronJob() {
   case "$1" in
      zip)
         gzip $CB_CRONJOB && return 1
      ;;
      unzip)
         gunzip -f $CB_CRONJOB.gz && return 1
      ;;
      status)
         if [ -e $CB_CRONJOB ];
         then
            echo "Cronjob file($CB_CRONJOB) exist"
         else if [ -e $CB_CRONJOB.gz ];
              then
                 echo "Cronjob file($CB_CRONJOB) is zipped"
              else 
                 echo "Cronjob file($CB_CRONJOB) does not exist"
              fi
         fi
      ;;
   esac
}

# Check Network Connectivity; Set VAR_NETWORK_STATUS, 1 when success; 0 when fail
function CheckNetwork() {
   COUNT=`ping -c 4 -W 4 $MON_TARGET | grep received | grep received | sed -n 's/.* \([0-9]\) received.*/\1/p'`
   [[ "$COUNT" -gt 0 ]] && VAR_NETWORK_STATUS=1 || VAR_NETWORK_STATUS=0
}


# Check Lock File existance; Set VAR_LOCK_EXIST, 1 when file exist; 0 when file not exist;
function CheckLockFileExist() {
   [[ -f $LOCK_FILE ]] &&  VAR_LOCK_EXIST=1 || VAR_LOCK_EXIST=0
}

# Check Lock File created by this node; Set VAR_LOCK_BY_OWNER, 1 when file was create by this node; 0 for remote;
function CheckLockFileOwner() {
   CheckLockFileExist
   if [[ $VAR_LOCK_EXIST == 0 ]]; then
      VAR_LOCK_BY_LOCAL=0
   else
      MY_IP=`ip addr | egrep "inet .* brd" | grep -v secondary | awk '{ print $2}'`
      LOCK_FILE_WC=`cat $LOCK_FILE | wc -w` 
      [[ $LOCK_FILE_WC == 0 ]] && echo $MY_IP > $LOCK_FILE
      IP_MATCH=`cat $LOCK_FILE | grep "$MY_IP"` 
      [[ -n $IP_MATCH ]] && VAR_LOCK_BY_LOCAL=1 || VAR_LOCK_BY_LOCAL=0
   fi
}


# Is Lock file update in 90 seconds? Return 1 when file was updated in 90 seconds; Otherwise, return 0;
function CheckLockFileActiveState() {
   LAST_TOUCH_COUNT=`find $LOCK_FILE -mmin -$LAST_DURATION 2>/dev/null | wc -l`
   [[ "$LAST_TOUCH_COUNT" == "1" ]] && VAR_LOCK_VALID=1 || VAR_LOCK_VALID=0
}

# Clean Lock file
function RemoveLockFile() {
   rm -f $LOCK_FILE 2>/dev/null
}

# Write Lock file
function TouchLockFile() {
   `ip addr | egrep "inet .* brd" | grep -v secondary | awk '{ print $2}' > $LOCK_FILE`
}

# Check Services Status; Return the number of failed service
function CheckCbServices() {
   SERVICES=(cb-pgsql cb-datagrid cb-redis cb-rabbitmq cb-solr cb-nginx cb-datastore cb-coreservices cb-sensorservices cb-liveresponse cb-allianceclient cb-enterprised)

   # Core Services
   #SERVICES=(cb-pgsql cb-datagrid cb-redis cb-rabbitmq cb-solr cb-nginx cb-datastore cb-coreservices cb-sensorservices cb-enterprised)
   
   COUNT_UP=0
   COUNT_TOTAL=0   

   for svc in "${SERVICES[@]}"
   do
      COUNT_TOTAL=$((COUNT_TOTAL + 1))

      # Check the service status
      res=`/usr/share/cb/cbservice $svc status | grep RUNNING | wc -l`
      if [ "$res" == "1" ]
      then
         COUNT_UP=$((COUNT_UP + 1))
      fi
   done
  
   VAR_SVC_STATUS=$((COUNT_TOTAL - COUNT_UP))
}

# Start Services
function StartCbServices() {
   /etc/init.d/cb-enterprise start
}

# Stop Services
function StopCbServices() {
   SERVICES=(cb-enterprised cb-allianceclient cb-liveresponse cb-sensorservices cb-coreservices cb-datastore cb-nginx cb-solr cb-rabbitmq cb-redis cb-datagrid cb-pgsql)
   for svc in "${SERVICES[@]}"
   do
      /usr/share/cb/cbservice $svc stop
   done
   systemctl stop cb-enterprise
}


# Check Mount Status; 0=both are not mounted; 1=/var/cb mounted; 2=/var/log/cb mounted; 3=both are mounted
function CheckMountStatus() {
   STATE_CB=`mount | grep $PART_DATA | wc -l`
   STATE_LOG=`mount | grep $PART_LOG | wc -l`
   STATE=0
   if [ "$STATE_CB" == "1" ];
   then
      STATE=1
   fi
   if [ "$STATE_LOG" == "1" ];
   then
      STATE=$(( STATE + 2 ))
   fi
   VAR_MOUNT_STATUS=$STATE
}

# Mount Partition
function MountPartition() {
   mount $PART_DATA && TouchLockFile
   [[ $PART_MOUNT_STATE -eq 3 ]] && mount $PART_LOG
}

# Unmount Partition
function UnmountPartition() {
   RemoveLockFile
   umount $PART_DATA
   umount $PART_LOG
}

# Write Log File
function WriteLog() {
   LOG_FILE="/var/log/cb_failover.log"
   TIMESTAMP=`date +"%Y-%m-%d %H:%i:%s"`
   echo "$TIMESTAMP $1" >> $LOG_FILE
}

# Set Keepalive State; Parameter "UP" or "DOWN"
function SetKeepaliveState() {
   case $1
   in
      UP) rm -f /var/run/keepalive_down ;;
      DOWN) echo 1 > /var/run/keepalive_down ;;
      *) exit ;;
   esac
}

function CheckVIPStatus() {
   VAR_VIP_FOUND=`ip addr | egrep "inet .* secondary" | grep $VIRTUAL_IP | wc -l`
}

# Stop at any error
#set -e

# Check command line input
ACTION=$1
case "$ACTION" in
   "auto")

      ;;
   "master")
      # make sure all the service is stopped first
      #StopCbServices

      # Try to mount the partition
      CheckMountStatus
      if [ $VAR_MOUNT_STATUS -lt $PART_MOUNT_STATE ]; then
         echo -n "Mount Partitions ... ... "
         MountPartition
         sleep 5
         CheckMountStatus
	 if [ $VAR_MOUNT_STATUS -eq $PART_MOUNT_STATE ]; then
            echo "Done"
		
            echo -n "Check LOCK file($LOCK_FILE) ... ... "
            if [ "$VAR_LOCK_EXIST" == "1" ]; then 
	       echo "Found"

               CheckLockFileOwner
               echo -n "Check LOCK file($LOCK_FILE) owner ... ... "
               [[ "$VAR_LOCK_BY_LOCAL" == "1" ]] && echo "Current Host";  CheckLockFileActiveState || echo "Remote Host"

               if [ "$VAR_LOCK_EXIST" == "0" ]; then 
                  echo "The remote host is updating the files in partition. Please umount the partition in remote host, wait a couple minutes and try again."
                  exit 0
               fi
            fi
         else
            echo "Failed"
            echo "Error Partition mount failed. Please umount in remote host and try again."
            exit 0
         fi
      fi

      #echo "Start Carbon Black Services ... ... " &&
      StartCbServices && CheckCbServices
     
      if [ $VAR_SVC_STATUS -eq 0 ];
      then
         #echo "Done"

         echo -n "Enable Carbon Black Cronjob ... ... "
         CbCronJob unzip
         echo "Done" 
      
         echo -n "Force VIP failover ... ... "
         SetKeepaliveState UP
         echo "Done"
      else
         echo "Failed"
      fi
      ;;
   "backup")
      echo "Stop Carbon Black Services ... ... "
      StopCbServices

      echo -n "Disable Carbon Black Cronjob ... ... "
      CbCronJob zip
      echo "Done" 
      
      CheckLockFileExist
      CheckLockFileOwner
      if [ $VAR_LOCK_EXIST -eq 1 ] && [ $VAR_LOCK_BY_LOCAL -eq 1 ];
      then 
         echo -n "Remove partition LOCK file ... ... "
         RemoveLockFile
         echo "Done" 
      fi

      CheckMountStatus
      if [ $VAR_MOUNT_STATUS -gt 0 ];
      then
         echo -n "Unmount Partitions ... ... "
         UnmountPartition
         echo "Done"
      fi 

      echo -n "Force VIP failover ... ... "
      SetKeepaliveState DOWN
      echo "Done"
      ;;
   "status")
      printf "%-50s %10s" "Check network connection($MON_TARGET)" " ... ... "
      CheckNetwork
      [[ $VAR_NETWORK_STATUS == 1 ]] && echo "Connected" || echo "Not Connected"

      printf "%-50s %10s" "Check partition mount status" " ... ... "
      CheckMountStatus
      if [ "$VAR_MOUNT_STATUS" == "$PART_MOUNT_STATE" ]; then
         echo "Mounted"

         printf "%-50s %10s" "Check LOCK file($LOCK_FILE) owner" " ... ... "
         CheckLockFileOwner
         if [ $VAR_LOCK_BY_LOCAL -eq 1 ]; then
            echo "Current Host"
         else 
            echo "Remote Host"

            printf "%-50s %10s" "Check LOCK file($LOCK_FILE) state" " ... ... "
            CheckLockFileActiveState
            [[ "$VAR_LOCK_BY_LOCAL" == 1 ]] && echo "Active" || echo "Inactive"
         fi
      else
         echo "Not Mounted"
      fi

      printf "%-50s %10s" "Check Virtual IP binding status" " ... ... "
      CheckVIPStatus
      [[ $VAR_VIP_FOUND -eq 1 ]] && echo "Bound" || echo "Not Bound"

      printf "%-50s %10s" "Checking Carbon Black Service status" " ... ... "
      CheckCbServices
      [[ $VAR_SVC_STATUS -eq 0  ]] && echo "Running" || echo "Stopped"
      ;;
   "writelock")
      # Call by cronjob to update the LOCK file
      CheckMountStatus
      CheckLockFileOwner

      if [ $VAR_LOCK_EXIST -eq 0 ]; then 
         CheckCbServices
         if [ $VAR_MOUNT_STATUS -ge $PART_MOUNT_STATE ] && [ $VAR_SVC_STATUS -ge 0 ]; then
            TouchLockFile
            echo "MOUNT Status: $VAR_MOUNT_STATUS; Exp Mount Count: $PART_MOUNT_STATE; SVC Status: $VAR_SVC_STATUS"
            cat $LOCK_FILE
         fi
      else
         [[ $VAR_LOCK_BY_LOCAL -eq 1 ]] && touch $LOCK_FILE 
      fi
      ;;
   "vrrp_up") 
      SetKeepaliveState UP 
      printf "%-50s %10s\n" "Enable Virtual IP" " ... ... Done" 
      echo "Note: the Virtual IP flating still depends on the keepalive service status weight. Please check keepalived.service status"
      ;;
   "vrrp_down") 
      SetKeepaliveState DOWN
      printf "%-50s %10s\n" "Disable Virtual IP" " ... ... Done" 
      echo "Note: the Virtual IP flating still depends on the keepalive service status weight. Please check keepalived.service status"
      ;;
   "mount")
      MountPartition
      printf "%-50s %10s" "Mount partitions" " ... ... " 
      CheckMountStatus
      [[ $VAR_MOUNT_STATUS -ge $PART_MOUNT_STATE ]] && echo "OK" || echo "Failed"
      ;;
   "unmount")
      UnmountPartition
      printf "%-50s %10s" "Unmount partitions" " ... ... " 
      [[ $VAR_MOUNT_STATUS -eq 0 ]] && echo "OK" || echo "Failed"
      ;;
   *)
      echo "Usage:$0 auto|master|backup|status|writelock|vrrp_up|vrrp_down|mount|unmount"
      ;;
esac

