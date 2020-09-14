#!/bin/bash

PS4='+(${BASH_SOURCE}:${LINENO}): ${FUNCNAME[0]:+${FUNCNAME[0]}(): }'
#set -x

PUBLIC_IP=$( curl http://checkip.amazonaws.com )
PUBLIC_HOSTNAME=$( wget -q -O - http://169.254.169.254/latest/meta-data/public-hostname )
INSTANCE_NAME="PR-12701"
DOCS_BUILD=0
KEEP_FILES=0
DRY_RUN=0
AVERAGE_SESSION_TIME=0.75 # Hours
GUILLOTINE=$( echo " 2 * $AVERAGE_SESSION_TIME * 60" | bc |  xargs printf "%.0f" ) # minutes ( 2 x AVERAGE_SESSION_TIME)
printf "AVERAGE_SESSION_TIME = %f hours, GUILLOTINE = %d minutes" "$AVERAGE_SESSION_TIME" "$GUILLOTINE"
 
while [ $# -gt 0 ]
do
    param=$1
    param=${param//-/}
    echo "Param: ${param}"
    case $param in
    
        instance*)  INSTANCE_NAME=${param//instanceName=/}
                INSTANCE_NAME=${INSTANCE_NAME//\"/}
                INSTANCE_NAME=${INSTANCE_NAME//PR/PR-}
                echo "Instance name: '${INSTANCE_NAME}'"
                ;;
                
        docs*)  DOCS_BUILD=${param//docs=True/1}
                DOCS_BUILD=${DOCS_BUILD//docs=False/0}
                echo "Build docs: '${DOCS_BUILD}'"
                ;;
               
        addGitC*) ADD_GIT_COMMENT=${param//addGitComment=True/1}
                ADD_GIT_COMMENT=${ADD_GIT_COMMENT//addGitComment=False/0}
                echo "Add git comment: ${ADD_GIT_COMMENT}"
                ;;
                
        commit*) COMMIT_ID=${param//commitId=/}
                COMMIT_ID=${COMMIT_ID//\"/}
                echo "Commit ID: ${COMMIT_ID}"
                ;;
                
                
        dryRun) DRY_RUN=1
                echo "Dry run."
                ;;
                
    esac
    shift
done

cat << DATASTAX_ENTRIES | sudo tee /etc/yum.repos.d/datastax.repo
[datastax]
name = DataStax Repo for Apache Cassandra
baseurl = http://rpm.datastax.com/community
enabled = 1
gpgcheck = 0
DATASTAX_ENTRIES

PACKAGES_TO_INSTALL="expect mailx dsc30 cassandra30 cassandra30-tools python-pip bc"
#if [ $DOCS_BUILD -eq 1 ]
#then
    wget http://mirror.centos.org/centos/7/os/x86_64/Packages/fop-1.1-6.el7.noarch.rpm
    PACKAGES_TO_INSTALL="$PACKAGES_TO_INSTALL fop-1.1"
#fi

echo "Packages to install: ${PACKAGES_TO_INSTALL}"
sudo yum install -y ${PACKAGES_TO_INSTALL}

[ ! -d smoketest ] && mkdir smoketest

cd smoketest

git clone https://github.com/HPCCSmoketest/scripts.git

# check scripts dir

cp scripts/*.sh .
cp scripts/*.py .

[ ! -d $INSTANCE_NAME ] && mkdir $INSTANCE_NAME

cd $INSTANCE_NAME
echo "Execute Smoketest on $INSTANCE_NAME" > test.log
cd ..


echo "Add items for crontab"

prId=${INSTANCE_NAME//PR-/}
INSTANCE_ID=$( wget -q -t1 -T1 -O - http://169.254.169.254/latest/meta-data/instance-id )

# Schedule smoketest in one or two minutes time
[[ $(date "+%-S") -ge 50 ]] && timeStep=1 || timeStep=1

if [[ $DRY_RUN -eq 0 ]]
then
    # For real
    ( crontab -l; echo $( date  -d "$today + $timeStep minute" "+%M %H %d %m") " * cd ~/smoketest; ./update.sh; export commitId=${COMMIT_ID}; export addGitComment=${ADD_GIT_COMMENT}; export runOnce=1; export keepFiles=$KEEP_FILES; export testOnlyOnePR=1; export testPrNo=$prId; export runFullRegression=1; export useQuickBuild=0; export skipDraftPr=0; export AVERAGE_SESSION_TIME=0.75; scl enable devtoolset-7 './smoketest.sh'" ) | crontab
    
    # Add self destruction with email notification
    ( crontab -l; echo ""; echo "# Self destruction initiated in ${GUILLOTINE} minutes"; echo $( date  -d "$today + ${GUILLOTINE} minutes" "+%M %H %d %m") " * sleep 10; echo \"At $(date '+%Y.%m.%d %H:%M:%S') the ${INSTANCE_ID} is still running, terminate it.\" | mailx -s \"Instance self-destruction initiated\" attila.vamos@gmail.com; sudo shutdown now " ) | crontab
    
    # Add self destruction without email notification
    #( crontab -l; echo ""; echo "# Self destruction initiated in ${GUILLOTINE} minutes"; echo $( date  -d "$today + ${GUILLOTINE} minutes" "+%M %H %d %m") " * sleep 10; sudo shutdown now " ) | crontab
else
    #For testing
    ( crontab -l; echo $( date  -d "$today + $timeStep minute" "+%M %H %d %m") " * cd ~/smoketest; ./update.sh; cd $INSTANCE_NAME; echo 'Build: success' > build.summary; export addGitComment=${ADD_GIT_COMMENT} " ) | crontab

    # Add self destruction without email notification
    ( crontab -l; echo ""; echo "# Self destruction initiated in 10 minutes"; echo $( date  -d "$today + 10 minutes" "+%M %H %d %m") " * sleep 10; sudo shutdown now " ) | crontab
fi

# Before self destruction initiate it would be nice to kill (send Ctrl-C/Ctrl-Break signal to) Regression Test Engine to put some log into the PR
BREAK_TIME=20 # $(( ${GUILLOTINE} - 10 ))
BREAK_TIME=$(( ${GUILLOTINE} - 10 ))
( crontab -l; echo ""; echo "# Send Ctrl - C to Regression Test Engine after ${BREAK_TIME} minutes"; echo $( date -d " + ${BREAK_TIME} minutes" "+%M %H %d %m") " * REGRESSION_TEST_ENGINE_PID=\$( pgrep -f ecl-test ); while [[ -z \"\$REGRESSION_TEST_ENGINE_PID\" ]] ; do date; sleep 10; REGRESSION_TEST_ENGINE_PID=\$( pgrep -f ecl-test ); done; echo \$REGRESSION_TEST_ENGINE_PID; sudo kill -2 \${REGRESSION_TEST_ENGINE_PID}; sleep 10; sudo kill -2 \${REGRESSION_TEST_ENGINE_PID}; " ) | crontab

# Install, prepare and stat Bokeh
echo install Bokeh
sudo pip install --upgrade pip
sudo yum remove -y pyparsing
sudo pip install pandas bokeh pyproj

echo "Prepare Bokeh"
cd ~/smoketest
# Don't use Public IP, out network may refuse to connect to it
#sed -e 's/origin=\(ec2.*\)/origin='"$PUBLIC_IP"':5006/g' ./startBokeh_templ.sh>  ./startBokeh.sh
#echo "Bokeh address: $PUBLIC_IP:5006"

# Use Public hostname isntead
sed -e 's/origin=\(ec2.*\)/origin='"$PUBLIC_HOSTNAME"':5006/g' ./startBokeh_templ.sh>  ./startBokeh.sh
echo "Bokeh address: $PUBLIC_HOSTNAME:5006"
echo "http://$PUBLIC_HOSTNAME:5006" > bokeh.url

echo "Start Bokeh"
chmod +x ./startBokeh.sh
./startBokeh.sh &
echo "Bokeh pid: $!"

echo "End of init.sh"
