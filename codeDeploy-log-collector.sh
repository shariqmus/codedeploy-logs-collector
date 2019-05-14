#!/bin/bash
#
#Maintained by Nithish K.
# - Collects Amazon CodeDeploy agent logs on Amazon Linux,
#   Redhat 7, Debian 8, ubuntu14.06. 
# - Collects general operating system logs.
#   on Amazon Linux variants.
#   For usage information, see --help.

export LANG="C"
export LC_ALL="C"

# Common options
curdir="$(dirname $0)"
infodir="${curdir}/collect"
info_system="${infodir}/system"

# Global options
pkgtype=''  # defined in get_sysinfo
os_name=''  # defined in get_sysinfo
progname='' # defined in parse_options


# Common functions
# ---------------------------------------------------------------------------------------

help()
{
  echo "USAGE: ${progname} [--mode=[brief]]"
  echo "       ${progname} --help"
  echo ""
  echo "OPTIONS:"
  echo "     --mode  Sets the desired mode of the script. For more information,"
  echo "             see the MODES section."
  echo "     --help  Show this help message."
  echo ""
  echo "MODES:"
  echo "     brief   Gathers basic operating system, Amazon"
  echo "             CodeDeploy agent logs. This is the default mode."
}

parse_options()
{
  local count="$#"

  progname="$0"

  for i in `seq ${count}`; do
    eval arg=\$$i
    param="`echo ${arg} | awk -F '=' '{print $1}' | sed -e 's|--||'`"
    val="`echo ${arg} | awk -F '=' '{print $2}'`"

    case "${param}" in
      mode)
        eval $param="${val}"
        ;;
      help)
        help && exit 0
        ;;
      *)
        echo "Command not found: '--$param'"
        help && exit 1
        ;;
    esac
  done
}

ok()
{
  echo "ok"
}

info()
{
  echo "$*"
}

try()
{
  echo -n "Trying to $*... "
}

warning()
{
  echo "Warning $*.. "
}

fail()
{
  echo "failed"
}

die()
{
  echo "ERROR: $*.. exiting..."
  exit 1
}

is_root()
{
  try "check if the script is running as root"

  if [[ "$(id -u)" != "0" ]]; then
    die "This script must be run as root!"

  fi

  ok
}

is_diskfull()
{
  try "check disk space usage"

  threshold=70
  i=2
  result=`df -kh |grep -v "Filesystem" | awk '{ print $5 }' | sed 's/%//g'`

  for percent in ${result}; do
    if [[ "${percent}" -gt "${threshold}" ]]; then
      partition=`df -kh | head -$i | tail -1| awk '{print $1}'`
      warning "${partition} is ${percent}% full, please ensure adequate disk space to collect and store the log files."
    fi
    let i=$i+1
  done

  ok
}

cleanup()
{
  rm -rf ${infodir} >/dev/null 2>&1
  rm -f ${curdir}/collect.tgz
}

collect_brief() {
  is_root
  is_diskfull
  get_sysinfo
  get_common_logs
  get_kernel_logs
  get_mounts_info
  get_selinux_info
  get_pkglist
  get_system_services
  get_CD_agent_logs
  get_CD_deployment_script_logs
  get_CodeDeployagent_info
}

pack()
{
  try "archive gathered log information"

  local tar_bin
  tar_bin="`which tar 2>/dev/null`"
  [ -z "${tar_bin}" ] && warning "TAR archiver not found, please install a TAR archiver to create the collection archive. You can still view the logs in the collect folder."

  cd ${curdir}
  ${tar_bin} -czf ${infodir}.tgz ${infodir} > /dev/null 2>&1

  ok
}

get_sysinfo()
{
  try "collect system information"

  res="`/bin/uname -m`"
  [ "${res}" = "amd64" -o "$res" = "x86_64" ] && arch="x86_64" || arch="i386"

  found_file=""
  for f in system-release redhat-release lsb-release debian_version; do
    [ -f "/etc/${f}" ] && found_file="${f}" && break
  done

  case "${found_file}" in
    system-release)
      pkgtype="rpm"
      if grep --quiet "Amazon" /etc/${found_file}; then
        os_name="amazon"
      elif grep --quiet "Red Hat" /etc/${found_file}; then
        os_name="redhat"
      fi
      ;;
    debian_version)
      pkgtype="deb"
      if grep --quiet "8" /etc/${found_file}; then
        os_name="debian"
      fi
      ;;
    lsb-release)
      pkgtype="deb"
      if grep --quiet "Ubuntu 14.04" /etc/${found_file}; then
        os_name="ubuntu14"
      fi
      ;;
    *)
      fail
      die "Unsupported OS detected."
      ;;
  esac

  ok
}

get_mounts_info()
{
  try "get mount points and volume information"
  mkdir -p ${info_system}
  mount > ${info_system}/mounts.txt
  echo "" >> ${info_system}/mounts.txt
  df -h >> ${info_system}/mounts.txt

  ok
}

get_selinux_info()
{
  try "check SELinux status"

  enforced="`getenforce 2>/dev/null`"

  [ "${pkgtype}" != "rpm" -o -z "${enforced}" ] \
        && info "not installed" \
        && return

  mkdir -p ${info_system}
  echo -e "SELinux mode:\n    ${enforced}" >  ${info_system}/selinux.txt

  ok
}

get_common_logs()
{
  try "collect common operating system logs"
  dstdir="${info_system}/var_log"
  mkdir -p ${dstdir}

  for entry in syslog messages cloud-init.log cfn-init.log cfn-wire.log; do
    [ -e "/var/log/${entry}" ] && cp -fR /var/log/${entry} ${dstdir}/
  done

  ok
}

get_kernel_logs()
{
    try "collect kernel logs"
    dstdir="${info_system}/kernel"
    mkdir -p "$dstdir"
    if [ -e "/var/log/dmesg" ]; then
	cp -f /var/log/dmesg "$dstdir/dmesg.boot"
    fi
    dmesg > "$dstdir/dmesg.current"
    ok
}

get_CD_agent_logs()
{
  try "collect Amazon CodeDeploy agent logs"
  dstdir="${info_system}/CodeDeploy-agent-log"

  mkdir -p ${dstdir}
  for entry in codedeploy-agent.log*; do
    cp -fR /var/log/aws/codedeploy-agent/${entry} ${dstdir}/
  done

  ok
}

get_CD_deployment_script_logs()
{
  try "collect Amazon CodeDeploy deployment script logs"
  dstdir="${info_system}/CodeDeploy-Deployment-Script-logs"

  mkdir -p ${dstdir}
  for entry in codedeploy-agent-deployments.*; do
    cp -fR /opt/codedeploy-agent/deployment-root/deployment-logs/${entry} ${dstdir}/
    cp -frR /opt/codedeploy-agent/deployment-root/deployment-instructions/* ${dstdir}/
  done

  ok
}

get_pkglist()
{
  try "detect installed packages"

  mkdir -p ${info_system}
  case "${pkgtype}" in
    rpm)
      rpm -qa >${info_system}/pkglist.txt 2>&1
      ;;
    deb)
      dpkg --list > ${info_system}/pkglist.txt 2>&1
      ;;
    *)
      warning "Unknown package type."
      ;;
  esac

  ok
}

get_system_services()
{
  try "detect active system services list"
  mkdir -p ${info_system}
  case "${os_name}" in
    amazon)
      chkconfig --list > ${info_system}/services.txt 2>&1
      ;;
    redhat)
      /bin/systemctl list-units > ${info_system}/services.txt 2>&1
      ;;
    debian)
      /bin/systemctl list-units > ${info_system}/services.txt 2>&1
      ;;
    ubuntu14)
      /sbin/initctl list | awk '{ print $1 }' | xargs -n1 initctl show-config > ${info_system}/services.txt 2>&1
      printf "\n\n\n\n" >> ${info_system}/services.txt 2>&1
      /usr/bin/service --status-all >> ${info_system}/services.txt 2>&1
      ;;
    *)
      warning "Unable to determine active services."
      ;;
  esac

  top -b -n 1 > ${info_system}/top.txt 2>&1
  ps -fauxwww > ${info_system}/ps.txt 2>&1
  netstat -plant > ${info_system}/netstat.txt 2>&1

  ok
}

get_CodeDeployagent_info()
{
  try "gather CodeDeploy agent information"

   mkdir -p ${info_system}/CodeDeploy-agent-Info

    service codedeploy-agent status > ${info_system}/CodeDeploy-agent-Info/CD-agent-pid-info.txt
    echo $(cat /opt/codedeploy-agent/.version) > ${info_system}/CodeDeploy-agent-Info/CodeDeploy_version.txt
    cp -fR /tmp/codedeploy-agent.update.log ${info_system}/CodeDeploy-agent-Info/
    cp -fR /etc/codedeploy-agent/conf/*yml ${info_system}/CodeDeploy-agent-Info/

    ok

}

# --------------------------------------------------------------------------------------------

parse_options $*

[ -z "${mode}" ] && mode="brief"

case "${mode}" in
  brief)
    cleanup
    collect_brief
    ;;
  debug)
    cleanup
    ;;
  *)
    help && exit 1
    ;;
esac

pack
