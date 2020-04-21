#!/bin/bash

PS4='+(${BASH_SOURCE}:${LINENO}): ${FUNCNAME[0]:+${FUNCNAME[0]}(): }'
#set -x

#
#------------------------------
#
# Import settings
#
# WriteLog() function

. ./timestampLogger.sh

#
#------------------------------
#
# MaiFunction
#

MyExit()
{
    errorCode=$1
    errorTitle=$2
    errorMsg=$3
    instanceName=$4
    commitId=$5

    # Check if instance running
    runningInstanceID=$( aws ec2 describe-instances --filters "Name=tag:Name,Values=${instanceName}" "Name=tag:Commit,Values=${commitId}" --query "Reservations[].Instances[].InstanceId" --output text )
    publicIP=$( aws ec2 describe-instances --filters "Name=tag:Name,Values=${instanceName}" "Name=tag:Commit,Values=${commitId}" --query "Reservations[].Instances[].PublicIpAddress" --output text )
    [[ -z ${publicIP} ]] && publicIP="N/A"
    
    if [[ -n ${runningInstanceID} ]]
    then
        terminate=$( aws ec2 terminate-instances --instance-ids ${runningInstanceID} 2>&1 )
        WriteLog "Terminate in MyExit() function:\n ${terminate}" "$LOG_FILE"
    fi

    (echo "At $(date "+%Y.%m.%d %H:%M:%S") session (instance ID: ${runningInstanceID} on IP: ${publicIP}) exited with error code: $errorCode."; echo "${errorMsg}"; echo "${terminate}" ) | mailx -s "Abnormal end of session $instanceName ($commitId) on ${publicIP}" attila.vamos@gmail.com

    exit $errorCode
}

#
#------------------------------
#
# Main
#

DOCS_BUILD=0
SMOKETEST_HOME=
ADD_GIT_COMMENT=0
INSTANCE_NAME="PR-12701"
DRY_RUN=''  #"-dryRun"
LOG_FILE="/dev/null"


while [ $# -gt 0 ]
do
    param=$1
    param=${param//-/}
    WriteLog "Param: ${param}" "$LOG_FILE"
    case $param in
    
        instance*)  INSTANCE_NAME=${param//instanceName=/}
                INSTANCE_NAME=${INSTANCE_NAME//\"/}
                INSTANCE_NAME=${INSTANCE_NAME//PR/PR-}
                WriteLog "Instancename: '${INSTANCE_NAME}'" "$LOG_FILE"
                ;;
                
        docs*)  DOCS_BUILD=${param}
                WriteLog "Build docs: '${DOCS_BUILD}'" "$LOG_FILE"
                ;;
                
        smoketestH*) SMOKETEST_HOME=${param//smoketestHome=/}
                SMOKETEST_HOME=${SMOKETEST_HOME//\"/}
                WriteLog "Smoketest home: '${SMOKETEST_HOME}'" "$LOG_FILE"
                ;;
                
        addGitC*) ADD_GIT_COMMENT=${param}
                WriteLog "Add git comment: ${ADD_GIT_COMMENT}" "$LOG_FILE"
                ;;
                
        commit*) COMMIT_ID=${param}
                WriteLog "CommitID: ${COMMIT_ID}" "$LOG_FILE"
                C_ID=${COMMIT_ID//commitId=/}
                ;;
                
        dryRun) DRY_RUN=${param}
                WriteLog "Dry run: ${DRY_RUN}" "$LOG_FILE"
                ;;
                
    esac
    shift
done

if [[ -z ${DRY_RUN} ]]
then
    INSTANCE_TYPE="m4.4xlarge"      # 0.888 USD per Hour (16 Cores, 64 GB RAM)
    #INSTANCE_TYPE="m4.10xlarge"    # 2.22 USD per Hour (40 Cores, 163GB RAM)
    #INSTANCE_TYPE="m4.16xlarge"    # 3.552 USD per Hour (64 Cores, 256 GB RAM)
    instanceDiskVolumeSize=20       # GB
else
    INSTANCE_TYPE="t2.micro"
    instanceDiskVolumeSize=8        # GB    
fi


SSH_KEYFILE="~/HPCC-Platform-Smoketest.pem"
SSH_OPTIONS="-oConnectionAttempts=3 -oConnectTimeout=20 -oStrictHostKeyChecking=no"

#AMI_ID=$( aws ec2 describe-images --owners 446598291512 | egrep -i -B10 '-el7-' | egrep -i '"available"|"ImageId"' | egrep -i '"ImageId"' | tr -d "[:space:]" | cut -d":" -f2 )
AMI_ID="ami-0f6f902a9aff6d384"
SECURITY_GROUP_ID="sg-08a92c3135ec19aea"
SUBNET_ID="subnet-0f5274ec85eec91da"

WriteLog "Create instance for ${INSTANCE_NAME}, type: $INSTANCE_TYPE, disk: $instanceDiskVolumeSize, build ${DOCS_BUILD}" "$LOG_FILE"

instance=$( aws ec2 run-instances --image-id ${AMI_ID} --count 1 --instance-type $INSTANCE_TYPE --key-name HPCC-Platform-Smoketest --security-group-ids ${SECURITY_GROUP_ID} --subnet-id ${SUBNET_ID} --instance-initiated-shutdown-behavior terminate --block-device-mappings "[{\"DeviceName\":\"/dev/sda1\",\"Ebs\":{\"VolumeSize\":$instanceDiskVolumeSize,\"DeleteOnTermination\":true,\"Encrypted\":true}}]" 2>&1 )
retCode=$?
WriteLog "Ret code: $retCode" "$LOG_FILE"
WriteLog "Instance: $instance" "$LOG_FILE"

instanceId=$( echo "$instance" | egrep 'InstanceId' | tr -d '", ' | cut -d : -f 2 )
WriteLog "Instance ID: $instanceId" "$LOG_FILE"

if [[ -z "$instanceId" ]]
then
   WriteLog "Instance creation failed, exit" "$LOG_FILE"
   WriteLog "$instance" > ${SMOKETEST_HOME}/${INSTANCE_NAME}/build.summary
   MyExit "-1" "Instance creation failed, exit" "$instance" "${INSTANCE_NAME}" "${C_ID}"
fi

instanceInfo=$( aws ec2 describe-instances --instance-ids ${instanceId} 2>&1 | egrep -i 'instan|status|public|volume' )
WriteLog "Instance info: $instanceInfo" "$LOG_FILE"

instancePublicIp=$( echo "$instanceInfo" | egrep 'PublicIpAddress' | tr -d '", ' | cut -d : -f 2 )
WriteLog "Public IP: ${instancePublicIp}" "$LOG_FILE"

volumeId=$( echo "$instanceInfo" | egrep 'VolumeId' | tr -d '", ' | cut -d : -f 2 )
WriteLog "Volume ID: $volumeId" "$LOG_FILE"

tag=$( aws ec2 create-tags --resources ${instanceId} ${volumeId} \
           --tags Key=market,Value=in-house-test \
                  Key=product,Value=hpcc-platform \
                  Key=application,Value=q-and-a \
                  Key=Name,Value=${INSTANCE_NAME} \
                  Key=project,Value=smoketest \
                  Key=service,Value=s3bucket \
                  Key=lifecycle,Value=dev \
                  Key=owner_email,Value=attila.vamos@lexisnexisrisk.com \
                  Key=support_email,Value=attila.vamos@lexisnexisrisk.com \
                  Key=purpose,Value=Smoketest \
                  Key=PR,Value=${INSTANCE_NAME} \
                  Key=Commit,Value=${C_ID} \
        2>&1 )
WriteLog "Tag: ${tag}" "$LOG_FILE"
        
WriteLog "Wait ~2 minutes for initialise instance" "$LOG_FILE"
sleep 1m

tryCount=6
 
while [[ $tryCount -ne 0 ]] 
do
    WriteLog "Check user directory ($tryCount)" "$LOG_FILE"
    res=$( ssh -i ${SSH_KEYFILE} ${SSH_OPTIONS} centos@${instancePublicIp} "ls -l" 2>&1 )
    retCode=$?
    WriteLog "Return code: $retCode, res: $res" "$LOG_FILE"

    [ $retCode -eq 0 ] && break

    sleep 20
    tryCount=$(( $tryCount-1 )) 

done

if [[ $tryCount -ne 0 ]] 
then

    WriteLog "Upload token.dat files into smoketest directory" "$LOG_FILE"
    res=$( rsync -var --timeout=60 -e "ssh -i ${SSH_KEYFILE} ${SSH_OPTIONS}" ${SMOKETEST_HOME}/token.dat centos@${instancePublicIp}:/home/centos/smoketest/ 2>&1 )
    WriteLog "Res: $res" "$LOG_FILE"

    if [ -d ${SMOKETEST_HOME}/${INSTANCE_NAME} ]
    then

        WriteLog "Upload *.dat files" "$LOG_FILE"
        res=$( rsync -var --timeout=60 -e "ssh -i ${SSH_KEYFILE} ${SSH_OPTIONS}" ${SMOKETEST_HOME}/${INSTANCE_NAME}/*.dat centos@${instancePublicIp}:/home/centos/smoketest/${INSTANCE_NAME}/ 2>&1 )
        WriteLog "Res: $res" "$LOG_FILE"
         
        if [[ -f ${SMOKETEST_HOME}/${INSTANCE_NAME}/environment.xml ]]
        then
            WriteLog "Upload environment.xml file" "$LOG_FILE"
            res=$( rsync -var --timeout=60 -e "ssh -i ${SSH_KEYFILE} ${SSH_OPTIONS}" ${SMOKETEST_HOME}/${INSTANCE_NAME}/environment.xml centos@${instancePublicIp}:/home/centos/smoketest/${INSTANCE_NAME}/ 2>&1)
            WriteLog "Res: $res" "$LOG_FILE"
        fi
    fi


    WriteLog "Upload init.sh" "$LOG_FILE"
    res=$( rsync -va --timeout=60 -e "ssh -i ${SSH_KEYFILE} ${SSH_OPTIONS}" ${SMOKETEST_HOME}/init.sh centos@${instancePublicIp}:/home/centos/ 2>1& )
    WriteLog "Res: $res" "$LOG_FILE"

    WriteLog "Set it to executable" "$LOG_FILE"
    res=$( ssh -i ${SSH_KEYFILE} ${SSH_OPTIONS} centos@${instancePublicIp} "chmod +x init.sh" 2>&1 )
    WriteLog "Res: $res" "$LOG_FILE"

    WriteLog "Check user directory" "$LOG_FILE"
    res=$( ssh -i ${SSH_KEYFILE} ${SSH_OPTIONS} centos@${instancePublicIp} "ls -l" 2>&1 )
    WriteLog "Res: $res" "$LOG_FILE"

    WriteLog "Execute init.sh" "$LOG_FILE"
    res=$( ssh -i ${SSH_KEYFILE} ${SSH_OPTIONS} centos@${instancePublicIp} "~/init.sh -instanceName=${INSTANCE_NAME} ${DOCS_BUILD} ${ADD_GIT_COMMENT} ${COMMIT_ID} ${DRY_RUN}" 2>&1 )
    WriteLog "Res: $res" "$LOG_FILE"

    WriteLog "Check user directory" "$LOG_FILE"
    res=$( ssh -i ${SSH_KEYFILE} ${SSH_OPTIONS} centos@${instancePublicIp} "ls -l" 2>&1 )
    WriteLog "Res: $res" "$LOG_FILE"

    if [[ ${DOCS_BUILD} -ne 0 ]]
    then
        WriteLog "Check fop" "$LOG_FILE"
        res=$( ssh -i ${SSH_KEYFILE} ${SSH_OPTIONS} centos@${instancePublicIp} "/usr/bin/fop -version" 2>&1 )
        WriteLog "Res: $res" "$LOG_FILE"
    fi
    
    WriteLog "Check Smoketest" "$LOG_FILE"
    res=$( ssh -i ${SSH_KEYFILE} ${SSH_OPTIONS} centos@${instancePublicIp} "ls -l ~/smoketest/" 2>&1 )
    WriteLog "Res: $res" "$LOG_FILE"

    WriteLog "Check crontab" "$LOG_FILE"
    res=$( ssh -i ${SSH_KEYFILE} ${SSH_OPTIONS} centos@${instancePublicIp} "crontab -l" 2>&1 )
    WriteLog "Res: $res" "$LOG_FILE"

    if [[ -z $DRY_RUN ]]
    then
        INIT_WAIT=2m
        LOOP_WAIT=1m
    else
        INIT_WAIT=1m
        LOOP_WAIT=1m
    fi
    
    WriteLog "Wait ${INIT_WAIT} before start checking Smoketest state" "$LOG_FILE"
    sleep ${INIT_WAIT}
    smoketestIsRunning=1
    checkCount=0
    emergencyLogDownloadThreshold=60  # minutes
    while [[ $smoketestIsRunning -eq 1 ]]
    do
        smoketestIsRunning=$( ssh -i ${SSH_KEYFILE} ${SSH_OPTIONS} centos@${instancePublicIp} "pgrep smoketest | wc -l"  2>&1 )
        if [[ $? -ne 0 ]]
        then
            # Something is wrong, try to find out what
            timeOut=$( echo "$smoketestIsRunning" | egrep 'timed out' | wc -l);
            if [[ $timeOut -eq 0 ]]
            then
                WriteLog "Sssh error, try again" "$LOG_FILE"
                smoketestIsRunning=1
            else
                WriteLog "Ssh timed out, chek if the instance is still running" "$LOG_FILE"
                isTerminated=$( aws ec2 describe-instances --filters "Name=tag:PR,Values=${INSTANCE_NAME}" --query "Reservations[].Instances[].State[].Name" | egrep -c 'terminated|stopped'  )
                if [[ $isTerminated -ne 0 ]]
                then
                    WriteLog "Instance is terminated, exit" "$LOG_FILE"
                    smoketestIsRunning=0
                    if [[ ! -f ${SMOKETEST_HOME}/${INSTANCE_NAME}/build.summary ]] 
                    then
                        WriteLog "Instance is terminated, exit." "${SMOKETEST_HOME}/${INSTANCE_NAME}/build.summary"
                    fi
                    MyExit "-3" "Instance is terminated, exit." "No further informations" "${INSTANCE_NAME}" "${C_ID}"
                else
                    WriteLog "Instance is still running, try again" "$LOG_FILE"
                    smoketestIsRunning=1
                fi
            fi
        else
            WriteLog "Smoketest is $( [[ $smoketestIsRunning -eq 1 ]] && echo 'running.' || echo 'finished.')"  "$LOG_FILE"
            
            checkCount= $(( $checkCount + 1 ))
            
            # If session run time is longger than 1.25 * average_instance_time then we need to make emergency backup form logfiles regurarly (every 1-2 -3 minutes).
            if [[ ( $checkCount -ge $emergencyLogDownloadThreshold ) && ( $(( $checkCount % 2 )) -eq 0) ]]
            then
                WriteLog "This instance is running in $checkCount minutes (> $emergencyLogDownloadThreshold). Download its logs." "$LOG_FILE"
                res=$( rsync -va --timeout=60 --exclude=*.rpm --exclude=*.sh --exclude=*.py --exclude=*.txt --exclude=*.xml --exclude=build/* --exclude=HPCC-Platform/* -e "ssh -i ${SSH_KEYFILE} ${SSH_OPTIONS}" centos@${instancePublicIp}:/home/centos/smoketest/${INSTANCE_NAME}/* ${SMOKETEST_HOME}/${INSTANCE_NAME}/ 2>&1 )
                WriteLog "Res: $res" "$LOG_FILE"
            fi

        fi
        
        if [[ $smoketestIsRunning -eq 1 ]]
        then
            sleep ${LOOP_WAIT}
        fi
    done

    WriteLog "Check Smoketest" "$LOG_FILE"
    res=$( ssh -i ${SSH_KEYFILE} ${SSH_OPTIONS} centos@${instancePublicIp} "ls -l ~/smoketest/${INSTANCE_NAME}" 2>&1 )
    WriteLog "Res: $res" "$LOG_FILE"
    
    WriteLog "Smoketest finished." "$LOG_FILE"
    age=2 # minutes
    WriteLog "Archive previous test session logs and other files older than $age minutes."  "$LOG_FILE"
    timestamp=$(date "+%Y-%m-%d_%H-%M-%S")
     # Move all *.log, *test*.summary, *.diff, *.txt and *.old files into a zip archive.
    # TO-DO check if there any. e.g. for a new PR there is not any file to archive
    res=$( find ${SMOKETEST_HOME}/${INSTANCE_NAME}/ -maxdepth 1 -mmin +$age -type f -iname '*.log' -o -iname '*test*.summary' -o -iname '*.diff' -o -iname '*.txt' -o -iname '*.old' | zip -m -u ${SMOKETEST_HOME}/${INSTANCE_NAME}/old-logs-${timestamp} -@ 2>&1 )
    WriteLog "Res: $res" "$LOG_FILE"
    
    WriteLog "Compress and download result" "$LOG_FILE"
    res=$( ssh -i ${SSH_KEYFILE} ${SSH_OPTIONS} centos@${instancePublicIp} "zip -m /home/centos/smoketest/${INSTANCE_NAME}/HPCCSystems-regression-$(date '+%y-%m-%d_%H-%M-%S') -r /home/centos/smoketest/${INSTANCE_NAME}/HPCCSystems-regression/* > /home/centos/smoketest/${INSTANCE_NAME}/HPCCSystems-regression-$(date '+%y-%m-%d_%H-%M-%S').log 2>&1" 2>&1 )
    WriteLog "Res: $res" "$LOG_FILE"
    
    res=$( ssh -i ${SSH_KEYFILE} ${SSH_OPTIONS} centos@${instancePublicIp} "rm -rf /home/centos/smoketest/${INSTANCE_NAME}/HPCC-Platform /home/centos/smoketest/${INSTANCE_NAME}/build" 2>&1 )
    WriteLog "Res: $res" "$LOG_FILE"
    
    res=$( rsync -va --timeout=60 --exclude=*.rpm --exclude=*.sh --exclude=*.py --exclude=*.txt -e "ssh -i ${SSH_KEYFILE} ${SSH_OPTIONS}" centos@${instancePublicIp}:/home/centos/smoketest/${INSTANCE_NAME} ${SMOKETEST_HOME}/ 2>&1 )
    WriteLog "Res: $res" "$LOG_FILE"
    
    res=$( rsync -va --timeout=60 -e "ssh -i ${SSH_KEYFILE} ${SSH_OPTIONS}" centos@${instancePublicIp}:/home/centos/smoketest/SmoketestInfo.csv ${SMOKETEST_HOME}/${INSTANCE_NAME}/SmoketestInfo-${INSTANCE_NAME}-$(date '+%y-%m-%d_%H-%M-%S').csv 2>&1 )
    WriteLog "Res: $res" "$LOG_FILE"
    
    res=$( rsync -va --timeout=60 -e "ssh -i ${SSH_KEYFILE} ${SSH_OPTIONS}" centos@${instancePublicIp}:/home/centos/smoketest/prp-$(date '+%Y-%m-%d').log ${SMOKETEST_HOME}/${INSTANCE_NAME}/prp-$(date '+%Y-%m-%d')-${INSTANCE_NAME}-${instancePublicIp}.log 2>&1 )
    WriteLog "Res: $res" "$LOG_FILE"
    
else
    WriteLog "The try count exhausted before the instance became up and running." "$LOG_FILE"
    WriteLog "The try count exhausted before the instance became up and running." "${SMOKETEST_HOME}/${INSTANCE_NAME}/build.summary"
    WriteLog "$instance" "${SMOKETEST_HOME}/${INSTANCE_NAME}/build.summary"
    MyExit "-2" "The try count exhausted before the instance became up and running." "$instance" "${INSTANCE_NAME}" "${C_ID}"
fi

if [[ -z $DRY_RUN ]]
then
    WriteLog "Wait 10 seconds before terminate" "$LOG_FILE"
    sleep 10
else
    WriteLog "Wait 4 minutes before terminate" "$LOG_FILE"
    sleep 4m
fi

terminate=$( aws ec2 terminate-instances --instance-ids ${instanceId} 2>&1 )
WriteLog "Terminate: ${terminate}" "$LOG_FILE"

sleep 10

WriteLog "Instance:" "$LOG_FILE"
res=$( aws ec2 describe-instances --filters "Name=tag:PR,Values=${INSTANCE_NAME}" "Name=tag:Commit,Values=${C_ID}" | egrep -i 'instan|status|public' 2>&1 )
WriteLog "Res: $res" "$LOG_FILE"

WriteLog "End." "$LOG_FILE"
