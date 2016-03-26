#!/bin/bash

## execute the script NOT source
if [ x$0 = "xbash" ]; then
  echo "Error:  Please don't source me - just execute me!";
  exit -1;
fi;

######################################
BOOTUP=color
RES_COL=60
MOVE_TO_COL="echo -en \\033[${RES_COL}G"
SETCOLOR_SUCCESS="echo -en \\033[1;32m"
SETCOLOR_FAILURE="echo -en \\033[1;31m"
SETCOLOR_WARNING="echo -en \\033[1;33m"
SETCOLOR_NORMAL="echo -en \\033[0;39m"

## checking prereqisites
[ ! -e "/usr/bin/dig" ] && { echo "dig command not found; do : yum -y install bind-utils.x86_64"; exit -1; }
[ ! -e "/usr/bin/wget" ] && { echo "wget command not found; do : yum -y install wget.x86_64"; exit -1; }

# set arch for lib definition
[ `/bin/arch` == "x86_64" ] && export BITARCH=64

## find the location of xrd.sh script
SOURCE="${BASH_SOURCE[0]}"

# resolve $SOURCE until the file is no longer a symlink
#while [ -h "$SOURCE" ]; do
#  XRDSHDIR="$( cd -P "$( dirname "$SOURCE" )" && pwd )"
#  SOURCE="$(readlink "$SOURCE")"
#  # if $SOURCE was a relative symlink, we need to resolve it relative to the path where the symlink file was located
#  [[ $SOURCE != /* ]] && SOURCE="$DIR/$SOURCE"
#done
#XRDSHDIR="$( cd -P "$( dirname "$SOURCE" )" && pwd )"

export XRDSHDIR=`dirname $SOURCE`

# make sure xrd.sh is executable by user and user group
chmod ug+x ${XRDSHDIR}/xrd.sh

# location of configuration files; needs not be the same with xrd.sh location
XRDCONFDIR=${XRDCONFDIR:-$XRDSHDIR/xrootd.conf/}
export XRDCONFDIR

# location of logs, admin, core dirs
XRDRUNDIR=${XRDRUNDIR:-$XRDSHDIR/run/}
export XRDRUNDIR

## LOCATIONS AND INFORMATIONS
export XRDCONF="$XRDCONFDIR/system.cnf"

## READ system.cnf
source ${XRDCONF}

# ApMon files
export apmonPidFile=${XRDRUNDIR}/admin/apmon.pid
export apmonLogFile=${XRDRUNDIR}/logs/apmon.pid

## Find information about site from ML
TMP_SITEINFO="/tmp/site_info.txt"
wget -q http://alimonitor.cern.ch/services/se.jsp?se=${SE_NAME} -O $TMP_SITEINFO

export MONALISA_HOST_INFO=`host $(curl -s http://alimonitor.cern.ch/services/getClosestSite.jsp?ml_ip=true | awk -F, '{print $1}')`
export MONALISA_HOST=`echo $MONALISA_HOST_INFO | awk '{ print substr ($NF,1,length($NF)-1);}'`

export MANAGERHOST=`grep seioDaemons $TMP_SITEINFO | awk -F": " '{ gsub ("root://","",$2);gsub (":1094","",$2) ; print $2 }'`
export LOCALPATHPFX=`grep seStoragePath $TMP_SITEINFO | awk -F": " '{ print $2 }'`

rm -f ${TMP_SITEINFO}

USER=${USER:-$LOGNAME}
if [ -z "$USER" ] ; then USER=`id -nu` ; fi

SCRIPTUSER=$USER

## automatically asume that the owner of location of xrd.sh is XRDUSER
XRDUSER=`stat -c %U $XRDSHDIR`

## if xrd.sh is started by root get the home of the designated xrd user
if [ $USER = "root" ]; then
    USER=$XRDUSER
    XRDHOME=`su $XRDUSER  -c "/bin/echo \\\$HOME"`
    cd "$XRDHOME"

    if [ $? -eq 0 ]; then
        echo -n ""
    else
        echo Fatal: user '$XRDUSER' does not exist - check your system.conf - abort
        exit
    fi
else
    XRDHOME=$HOME
fi

## what is my hostname
if [ "x$myhost" = "x" ]; then
    myhost=`hostname -f`
fi

if [ "x$myhost" = "x" ]; then
    myhost=`hostname`
fi

if [ "x$myhost" = "x" ]; then
    myhost=$HOST
fi

if [ "x$myhost" = "x" ]; then
    echo "Cannot determine hostname. Aborting."
    exit 1
fi

echo "The fully qualified hostname appears to be $myhost"

## Network information and validity checking

MYIP=`dig @ns1.google.com -t txt o-o.myaddr.l.google.com +short | sed 's/\"//g' | awk -F, '{print $1}'`
ip_list=`/sbin/ip addr show scope global permanent up | grep inet | awk '{ split ($2,ip,"/"); print ip[1]}'`
found_at=`expr index "$ip_list" "$MYIP"`

[[ "$found_at" == "0" ]] && echo "Server without public/rutable ip. No NAT schema supported at this moment" && exit -1;

reverse=`host $MYIP | awk '{ print substr ($NF,1,length($NF)-1);}'`

[ "$myhost" != "$reverse" ] && { echo "detected hostname $myhost does not corespond to reverse dns name $reverse" && exit -1; }

#echo "host = "$myhost
#echo "reverse = "$reverse

##  What i am?
# default role - server
role="server";
server="yes";
nproc=1;

# unless i am manager
if [[ "x$myhost" == "x$MANAGERHOST" ]]
then
  role="manager";
  manager="yes";
  server="";
  nproc=1;
  if [[ "x$SERVERONREDIRECTOR" = "x1" ]] # i am am both add server role
  then
    role="all";
    server="yes";
    nproc=2;
  fi
fi


##########  FUNCTIONS   #############

echo_success() {
  [ "$BOOTUP" = "color" ] && $MOVE_TO_COL
  echo -n "[  "
  [ "$BOOTUP" = "color" ] && $SETCOLOR_SUCCESS
  echo -n $"OK"
  [ "$BOOTUP" = "color" ] && $SETCOLOR_NORMAL
  echo -n "  ]"
  echo -ne "\r"
  return 0
}

echo_failure() {
  [ "$BOOTUP" = "color" ] && $MOVE_TO_COL
  echo -n "[  "
  [ "$BOOTUP" = "color" ] && $SETCOLOR_FAILURE
  echo -n $"DOWN"
  [ "$BOOTUP" = "color" ] && $SETCOLOR_NORMAL
  echo -n "  ]"
  echo -ne "\r"
  return 0
}

echo_passed() {
  [ "$BOOTUP" = "color" ] && $MOVE_TO_COL
  echo -n "["
  [ "$BOOTUP" = "color" ] && $SETCOLOR_WARNING
  echo -n $"PASSED"
  [ "$BOOTUP" = "color" ] && $SETCOLOR_NORMAL
  echo -n "]"
  echo -ne "\r"
  return 1
}

checkkeys() {
    if [ "x$ACCLIB" != "x" ]; then
      installkeys=no
      [ ! -e $XRDHOME/.authz/xrootd/privkey.pem ] && installkeys=yes
      [ ! -e $XRDHOME/.authz/xrootd/pubkey.pem ] && installkeys=yes
      if [ x"$installkeys" = x"yes" ]; then
        mkdir -p $XRDHOME/.authz/xrootd/
        echo "Getting Keys and bootstrapping $XRDHOME/.authz/xrootd/TkAuthz.Authorization ..."
        wget -t 10 http://alitorrent.cern.ch/src/xrd3/keys/pubkey.pem -O $XRDHOME/.authz/xrootd/pubkey.pem
        wget -t 10 http://alitorrent.cern.ch/src/xrd3/keys/privkey.pem -O $XRDHOME/.authz/xrootd/privkey.pem
        chmod 400 $XRDHOME/.authz/xrootd/privkey.pem
        chmod 400 $XRDHOME/.authz/xrootd/pubkey.pem
      fi
      chown -R $XRDUSER $XRDHOME/.authz
      echo "KEY VO:*       PRIVKEY:$XRDHOME/.authz/xrootd/privkey.pem PUBKEY:$XRDHOME/.authz/xrootd/pubkey.pem" > $XRDHOME/.authz/xrootd/TkAuthz.Authorization
      chmod 600 $XRDHOME/.authz/xrootd/TkAuthz.Authorization
      cat $XRDCONFDIR/authz.cnf | grep EXPORT >> $XRDHOME/.authz/xrootd/TkAuthz.Authorization
      cat $XRDCONFDIR/authz.cnf | grep RULE >> $XRDHOME/.authz/xrootd/TkAuthz.Authorization
    fi
}

addcron() {
    rndname="/tmp/cron.$RANDOM.xrd.sh";
    crontab -l | grep -v "xrd.sh" | grep -v "\#" > $rndname;
    cat $XRDCONFDIR/crontab.xrootd >> $rndname;
    crontab $rndname;
#    crontab -l
    rm -f $rndname;
}

removecron() {
    rndname="/tmp/cron.$RANDOM.xrd.sh";
    crontab -l | grep -v "xrd\.sh" | grep -v "\#|" | grep -v XRDCONF | grep -v XRDRUN > $rndname;
    tabcontent=`cat $rndname`;
    if [ x"$tabcontent" = x ]; then
      crontab -r
    else
      crontab $rndname;
      rm -f $rndname;
    fi
}

createconf() {
  export osscachetmp=`echo -e $OSSCACHE`;

  # Replace XRDSHDIR for service starting
  cd ${XRDSHDIR}
  cp -f alicexrdservices.tmp alicexrdservices;
  perl -pi -e 's/XRDSHDIR/$ENV{XRDSHDIR}/g;' ${XRDSHDIR}/alicexrdservices;

  cd ${XRDCONFDIR}
  for name in `find . -type f | grep ".tmp"`; do
    newname=`echo $name | sed s/\.tmp// `;
    cp -f $name $newname;

    # Set xrootd site name
    perl -pi -e 's/SITENAME/$ENV{SE_NAME}/g;' ${XRDCONFDIR}/$newname;

    # Replace XRDSHDIR and XRDRUNDIR
    perl -pi -e 's/XRDSHDIR/$ENV{XRDSHDIR}/g; s/XRDRUNDIR/$ENV{XRDRUNDIR}/g;' ${XRDCONFDIR}/$newname;

    # Substitute all the variables into the templates
    perl -pi -e 's/BITARCH/$ENV{BITARCH}/g; s/LOCALPATHPFX/$ENV{LOCALPATHPFX}/g; s/LOCALROOT/$ENV{LOCALROOT}/g; s/XRDUSER/$ENV{XRDUSER}/g; s/MANAGERHOST/$ENV{MANAGERHOST}/g; s/XRDSERVERPORT/$ENV{XRDSERVERPORT}/g; s/XRDMANAGERPORT/$ENV{XRDMANAGERPORT}/g; s/CMSDSERVERPORT/$ENV{CMSDSERVERPORT}/g; s/CMSDMANAGERPORT/$ENV{CMSDMANAGERPORT}/g;	s/SERVERONREDIRECTOR/$ENV{SERVERONREDIRECTOR}/g;' ${XRDCONFDIR}/$newname;

    # write storage partitions
    perl -pi -e 's/OSSCACHE/$ENV{osscachetmp}/g;' ${XRDCONFDIR}/$newname;

    #	if [ -n "$OSSCACHE" ] ; then
    #	    echo -e "\n\n\n${OSSCACHE}\n\n\n" >> ${XRDCONFDIR}/$newname
    #	fi

    # Monalisa stuff which has to be commented out in some cases
    if [ "x$MONALISA_HOST" != "x" ] ; then
      perl -pi -e 's/MONALISA_HOST/$ENV{MONALISA_HOST}/g' ${XRDCONFDIR}/$newname
    else
      perl -pi -e 's/(.*MONALISA_HOST.*)/#\1/g' ${XRDCONFDIR}/$newname
    fi

    # XrdAcc stuff which has to be commented out in some cases
    if [ "x$ACCLIB" != "x" ] ; then
      perl -pi -e 's/ACCLIB/$ENV{ACCLIB}/g' ${XRDCONFDIR}/$newname
    else
      perl -pi -e 's/(.*ACCLIB.*)/#\1/g; s/(.*ofs\.authorize.*)/#\1/g' ${XRDCONFDIR}/$newname
    fi

    # Xrdn2n stuff which has to be commented out in some cases
    if [ -z "$LOCALPATHPFX" ] ; then
      perl -pi -e 's/(.*oss\.namelib.*)/#\1/g' ${XRDCONFDIR}/$newname
    fi

  done;

  #add variable definitions to cron job; crontab.xrootd already created above, so no modifications on crontab.xrootd.tmp
  cd $XRDCONFDIR
  ( /bin/echo -e "\nXRDCONFDIR=${XRDCONFDIR} \nXRDRUNDIR=${XRDRUNDIR}\n" && cat crontab.xrootd ) > crontab.xrootd2
  mv -f crontab.xrootd2 crontab.xrootd

  if [ ${SYSTEM} = "XROOTD" ]; then
    unlink ${XRDCONFDIR}/server/xrootd.cf  >&/dev/null ; ln -s ${XRDCONFDIR}/server/xrootd.xrootd.cf  ${XRDCONFDIR}/server/xrootd.cf;
    unlink ${XRDCONFDIR}/manager/xrootd.cf >&/dev/null ; ln -s ${XRDCONFDIR}/manager/xrootd.xrootd.cf ${XRDCONFDIR}/manager/xrootd.cf;
  elif [ ${SYSTEM} = "DPM" ]; then
    unlink ${XRDCONFDIR}/server/xrootd.cf  >&/dev/null ; ln -s ${XRDCONFDIR}/server/xrootd.dpm.cf  ${XRDCONFDIR}/server/xrootd.cf;
    unlink ${XRDCONFDIR}/manager/xrootd.cf >&/dev/null ; ln -s ${XRDCONFDIR}/manager/xrootd.dpm.cf ${XRDCONFDIR}/manager/xrootd.cf;

    if [ -z "$DPM_HOST" ]; then echo -e "\n\n##########################################################################\nWarning: you should define DPM_HOST in the environment of user $USER if you want to run with DPM!!!\n##########################################################################\n";fi
  fi;

  rm -f `find ${XRDCONFDIR}/ -name "*.template"`
  cd -;
}

bootstrap() {
  mkdir -p ${LOCALROOT}/${LOCALPATHPFX}
  [[ "x$role" == "xserver" ]] && chown $XRDUSER ${LOCALROOT}/${LOCALPATHPFX}
  createconf
}

getSrvToMon() {
    srvToMon=""
    if [  "x$SE_NAME" != "x" ] ; then se="${SE_NAME}_" ; fi

    for typ in manager server ; do
        for srv in xrootd cmsd ; do
            pid=`pgrep -f -U $USER "$srv .*$typ" | head -1`
            if [ "x$pid" != "x" ] ; then srvToMon="$srvToMon ${se}${typ}_${srv} $pid" ; fi
        done
    done
}

servMon() {
   if [ "x$SE_NAME" != "x" ] ; then se="${SE_NAME}_" ; fi
   startUp /usr/sbin/servMon.sh -p ${apmonPidFile} ${se}xrootd $*
   echo
}

startMon() {
    if [ "x$MONALISA_HOST" = "x" ] ; then return ; fi
    getSrvToMon
    echo -n "Starting ApMon [$srvToMon] ..."
    servMon -f $srvToMon
    echo_passed
    echo
}

killXRD() {
    echo -n "Stopping xrootd/cmsd: "

    pkill -u $USER xrootd
    pkill -u $USER cmsd
    sleep 1
    pkill -9 -u $USER xrootd
    pkill -9 -u $USER cmsd
    pkill -f -u $USER XrdOlbMonPerf
    pkill -f -u $USER mpxstats 

    echo_passed;
    echo

    echo -n "Stopping ApMon:"
    servMon -k
}

execEnvironment() {
    mkdir -p ${XRDRUNDIR}/logs/
    mkdir -p ${XRDRUNDIR}/core/${USER}_$1
    mkdir -p ${XRDRUNDIR}/admin/

    cd ${XRDRUNDIR}/core/${USER}_$1

#    echo "XRDSHDIR = "$XRDSHDIR
#    echo "XRDCONFDIR = "$XRDCONFDIR
#    echo "XRDRUNDIR = "$XRDRUNDIR

#    if [ $USER = "root" ]; then
#       EXECENV="ulimit -n ${XRDMAXFD};ulimit -c unlimited;"
#    else
#       EXECENV="ulimit -c unlimited;"
#    fi

    EXECENV="ulimit -c unlimited;"
    ulimit -n ${XRDMAXFD}

    fdmax=`ulimit -n`
    if [ $fdmax -lt 65000 ]; then
      echo "Fatal: This machine does not allow more than $fdmax file descriptors. At least 65000 are needed for serious operation - abort"
      exit -1
    fi

    chown -R $XRDUSER ${XRDRUNDIR}/core ${XRDRUNDIR}/logs ${XRDRUNDIR}/admin
    chmod -R 755 ${XRDRUNDIR}/core ${XRDRUNDIR}/logs ${XRDRUNDIR}/admin
}

startUp() {
    if [ $SCRIPTUSER = "root" ]; then
      cd "$XRDSHDIR"
      su -s /bin/bash $XRDUSER -c "${EXECENV} $*";
      echo_passed
      #	test $? -eq 0 && echo_success || echo_failure
      echo
    else
      ulimit -c unlimited
      $*
      echo_passed
      #	test $? -eq 0 && echo_success || echo_failure
      echo
    fi
}

handlelogs() {
  cd ${XRDRUNDIR}
  LOCK=${XRDRUNDIR}/logs/HANDLELOGS.lock
  mkdir -p ${XRDRUNDIR}/logsbackup

  todaynow=`date +%Y%m%d`

  cd ${XRDRUNDIR}/logs
  not_compressed=`find . -type f -not -name '*.bz2' -not -name 'stage_log' -not -name 'cmslog' -not -name 'xrdlog' -not -name 'pstg_log' -not -name 'xrd.watchdog.log' -not -name 'apmon.log' -print`

  if [[ ! -f $LOCK ]]; then
    touch $LOCK
    for log in $not_compressed; do bzip2 -9fq $log; done
  fi
  rm -f $LOCK

  # move compressed to logs backup
  mv -f ${XRDRUNDIR}/logs/*/*.bz2 ${XRDRUNDIR}/logsbackup/ &> /dev/null
}

restartXRD() {
    echo restartXRD
    killXRD

    if [ "x$manager" = "xyes" ]; then
      (
      execEnvironment manager || exit

      echo -n "Starting xrootd [manager]: "
      startUp /usr/bin/xrootd -n manager -b $XRDDEBUG -l ${XRDRUNDIR}/logs/xrdlog -c ${XRDCONFDIR}/manager/xrootd.cf -s ${XRDRUNDIR}/admin/xrd_mgr.pid

      echo -n "Starting cmsd   [manager]: "
      startUp /usr/bin/cmsd   -n manager -b $XRDDEBUG -l ${XRDRUNDIR}/logs/cmslog -c ${XRDCONFDIR}/manager/xrootd.cf -s ${XRDRUNDIR}/admin/cmsd_mgr.pid
      )
    fi

    if [ "x$server" = "xyes" ]; then
      (
      execEnvironment server || exit

      echo -n "Starting xrootd [server]: "
      startUp /usr/bin/xrootd -n server -b $XRDDEBUG -l ${XRDRUNDIR}/logs/xrdlog -c ${XRDCONFDIR}/server/xrootd.cf -s ${XRDRUNDIR}/admin/xrd_svr.pid
      echo -n "Starting cmsd   [server]: "
      startUp /usr/bin/cmsd   -n server -b $XRDDEBUG -l ${XRDRUNDIR}/logs/cmslog -c ${XRDCONFDIR}/server/xrootd.cf -s ${XRDRUNDIR}/admin/cmsd_svr.pid
      )
    fi
    startMon
}

checkstate()
{
sleep 1
echo "******************************************"
date
echo "******************************************"

nxrd=`pgrep -u $USER xrootd | wc -l | awk '{print $1}'`;
ncms=`pgrep -u $USER cmsd   | wc -l | awk '{print $1}'`;

returnval=0

if [ $nxrd -eq $nproc ]; then
  echo -n "xrootd:";
  echo_success;
  echo
else
  echo -n "xrootd:";
  echo_failure;
  echo
  returnval=1;
fi

if [ $ncms -eq $nproc ]; then
  echo -n "cmsd :";
  echo_success;
  echo
else
  echo -n "cmsd :";
  echo_failure;
  echo
  returnval=1;
fi

if [ -n "$MONALISA_HOST" ] ; then
  lines=`find $apmonPidFile* 2>/dev/null | wc -l`
  if [ "$lines" -gt 0 ] ; then
    echo -n "apmon:";
    echo_success;
    echo
  else
    echo -n "apmon:";
    echo_failure;
    echo
    returnval=1;
  fi
fi

exit $returnval
}

if [ "x$1" = "x-c" ]; then  ## check and restart if not running
    removecron
    checkkeys
    bootstrap
    addcron

    nxrd=`pgrep -u $USER xrootd | wc -l | awk '{print $1}'`;
    ncms=`pgrep -u $USER cmsd   | wc -l | awk '{print $1}'`;

    if [ $nxrd -lt $nproc -o $ncms -lt $nproc ]; then
      date
      echo "------------------------------------------"
      ps
      echo "------------------------------------------"
      echo "Starting all .... (only $nxrd xrootds $ncms cmsds)"
      restartXRD
      echo "------------------------------------------"
    else
      [ "x$MONALISA_HOST" != "x" ] && servMon
    fi
    handlelogs
    checkstate

elif [ "x$1" = "x-f" ]; then   ## force restart
    removecron
    checkkeys
    bootstrap
    addcron
    date
    echo "(Re-)Starting ...."
    restartXRD
    checkstate

elif [ "x$1" = "x-k" ]; then  ## kill running processes
    removecron
    killXRD
    checkstate

elif [ "x$1" = "x-logs" ]; then  ## handlelogs
    handlelogs

elif [ "x$1" = "x-conf" ]; then  ## create configuration
    createconf

else
    echo "usage: xrd.sh [-f] [-c] [-k]";
    echo " [-f] force restart";
    echo " [-c] check and restart if not running";
    echo " [-k] kill running processes";
    echo " [-logs] manage the logs";
    echo " [-conf] just (re)create configuration";
fi
