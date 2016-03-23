#!/bin/bash

## base on result/tags/*

MAX_NPROC=50
DELAY_SEC=1
TMP="/tmp/stat_layer_v2"
TOFETCH_LST="etc/layer_tofetch.lst"
FILE_SUCCESS="${TMP}/counter.success"
FILE_FAIL="${TMP}/counter.fail"

#TAG_RANGE could be "all" "latest"
[ $# -eq 0 ] && TAG_RANGE="latest" || TAG_RANGE=$1

WORKDIR=$(cd `dirname $0`; cd ..; pwd)
cd ${WORKDIR}
mkdir -p ${TMP}

function inc_job_result(){
  case $1 in
    success)
      read -u7 #fd7
      CNT_SUCESS=$(cat ${FILE_SUCCESS})
      CNT_SUCESS=$((CNT_SUCESS+1))
      echo ${CNT_SUCESS} >${FILE_SUCCESS}
      echo "[ inc_job_result : success:) ] [$2] ${CNT_SUCESS}/${TOTAL_TOFETCH}"
      echo >&7 #fd7
      ;;
    "not json"|fail)
      read -u8 #fd8
      CNT_FAIL=$(cat ${FILE_FAIL})
      CNT_FAIL=$((CNT_FAIL+1))
      echo ${CNT_FAIL} >${FILE_FAIL}
      echo "[ inc_job_result : $1:( ] [$2] ${CNT_FAIL}/${TOTAL_TOFETCH}"
      echo >&8 #fd8
      ;;
    *)
      echo "unknow job result"
      exit 1
  esac
}

############## main ##############
TOTAL_FULL=$(find result/tags -name "*.json" -type f | wc -l)
if [ ${TOTAL_FULL} -eq 0 ];then
  echo "result/tags is empty, please run ./run.sh get_tag first"
  exit 1
fi

# scan fetched result, generate ${TOFETCH_LST}
IDX=0
echo -n > ${TOFETCH_LST} #clear list
for f in $(find result/tags -name "*.json" -type f)
do
  IDX=$(( IDX + 1 ))
  ADD_FLAG=false
  #echo
  #echo "---------$f----------"
  tag_list=$(jq . $f 2>/dev/null | awk -F"[\":]" '{if($2!="")print $2 }')
  if [ "${tag_list}" == "" ];then
    echo "[ ${IDX} ] [ ${f} ] is not json, skip"
    continue
  fi

  layer_d=$( echo $f | awk -F"/" '{printf "%s/stat/v2/%s",$1,$3}')
  ns_name=$( echo $f | awk -F"[/.]" '{printf "%s",$3}')
  repo_name=$( echo $f | awk -F"[/.]" '{printf "%s",$4}')
  layer_f=${layer_d}/${repo_name}.csv

# for debug
#   cat <<EOF
#   -------------------------
#   tag_f    : $f
#   layer_d  : ${layer_d}
#   ns_name  : ${ns_name}
#   repo_name: ${repo_name}
#   layer_f  : ${layer_f}
#   tag_range: ${TAG_RANGE}
# EOF

  if [ "${TAG_RANGE}" == "all" ];then
    for l in ${tag_list}
    do
      echo $l
      if [ ! -s ${layer_f} ];then
        echo "${layer_f} not exist, need fetch"
        [ "${ADD_FLAG}" == "false" ] && echo -n "${ns_name}/${repo_name} " >> ${TOFETCH_LST}
        echo -n "|${l}" >> ${TOFETCH_LST}
        ADD_FLAG=true
      else
        grep ",$l," ${layer_f} >/dev/null 2>&1 #check tag in result
        if [ $? -ne 0 ];then
          echo "tag '$l' not in result '${layer_f}', need fetch"
          [ "${ADD_FLAG}" == "false" ] && echo -n "${ns_name}/${repo_name} " >> ${TOFETCH_LST}
          echo -n "|${l}" >> ${TOFETCH_LST}
          ADD_FLAG=true
        fi
      fi
    done
  else
    # if latest tag exist, then use latest, otherwise use the last tag
    LATEST=$(echo ${tag_list} | grep latest 2>/dev/null | wc -l)
    if [ ${LATEST} -ne 0 ];then
      #echo "[ ${IDX} ] [ ${repo_name} latest ] exist, use 'latest' tag"
      _TAG="latest"
    else
      #echo "[ ${IDX} ] [ ${repo_name} latest ] not exist, get the last tag"
      _TAG=$(echo ${tag_list} | tail -n1 | awk '{print $NF}' )
    fi
    grep ",${_TAG}," ${layer_f} >/dev/null 2>&1
    if [ $? -ne 0 ];then
      echo "[ ${IDX} ] [ ${layer_f} ] tag ${_TAG} not in is result, or result file not exist, need fetch"
      [ "${ADD_FLAG}" == "false" ] && echo -n "${ns_name}/${repo_name} " >> ${TOFETCH_LST}
      echo -n "|${_TAG}" >> ${TOFETCH_LST}
      ADD_FLAG=true
    else
      echo "[ ${IDX} ] [ ${layer_f} ] already exist, skip"
    fi
  fi
  if [ "${ADD_FLAG}" == "true" ];then
    #add /n
    echo >> ${TOFETCH_LST}
  fi
done

START_TS=$(date +"%s")
START_TIME=$(date +"%F %T")

# prepare pipe(for control concurrent tasks)
Pfifo="${TMP}/$$.fifo"
mkfifo $Pfifo $Pfifo.success $Pfifo.fail
# fd6: limit concurrent
exec 6<>$Pfifo #file descriptor(fd could be 0-9, except 0,1,2,5)
# fd7: success counter
exec 7<>$Pfifo.success
# fd8: fail counter
exec 8<>$Pfifo.fail

rm -f $Pfifo $Pfifo.success $Pfifo.fail

#init fd6, fd7, fd8
for((i=1; i<=$MAX_NPROC; i++));
do #write blank line as token
  echo
done >&6 #fd6
#init sucess counter
echo  >&7
#init fail counter
echo  >&8

echo -n 0 > ${FILE_SUCCESS}
echo -n 0 > ${FILE_FAIL}

# start fetch image tag from ${TOFETCH_LST}
JOB_TOTAL=0

TOTAL_TOFETCH=$(cat etc/layer_tofetch.lst|wc -l )
SKIP=$(( TOTAL_FULL - TOTAL_TOFETCH ))
echo
echo "##############################################"
echo "total: ${TOTAL_FULL} skip: ${SKIP} tofetch: ${TOTAL_TOFETCH}"
echo "##############################################"
[ ${TOTAL_TOFETCH} -gt 0 ] && echo ">start batch get tag ..."
echo
while read CURRENT_REPO TAG_LIST
do
  CMD_ARG=${TAG_LIST//|/ ${CURRENT_REPO}:} #replace | to repo_name
  #echo "${CMD_ARG}"
  _NS=$(echo ${CURRENT_REPO} | cut -d"/" -f1)
  _REPO=$(echo ${CURRENT_REPO} | cut -d"/" -f2)
  JOB_TOTAL=$((JOB_TOTAL+1))
  #fetch token from pipe(block here if there is no token in pipe)
  read -u6 #fd6
  {
    #exec job
    RLT_PATH=${WORKDIR}/result/stat/v2/${_NS}
    mkdir -p ${RLT_PATH}

    EXEC_CMD="${WORKDIR}/script/download-frozen-image-v2.sh ${CMD_ARG}"
    echo "start job: [ ${CURRENT_REPO} ${TAG_LIST} ] ..."
    eval "${EXEC_CMD}" && {
      #echo "Job finished: [${CURRENT_REPO}]"
      if [ -s ${RLT_PATH}/${_REPO}.csv ];then
        inc_job_result "success" "${CURRENT_REPO} ${TAG_LIST}"
      else
        inc_job_result "not json" "${CURRENT_REPO} ${TAG_LIST}"
      fi
    } || {
      #echo "Job failed: [${CURRENT_REPO}]"
      inc_job_result "fail" "${CURRENT_REPO} ${TAG_LIST}"
    }

    #echo "delay '${DELAY_SEC}' seconds"
    sleep ${DELAY_SEC}
    #give back token to pipe
    echo >&6 #fd6
  }&
done < etc/layer_tofetch.lst
#wait for all task finish
wait

# #read counter
JOB_SUCCESS=$(cat ${FILE_SUCCESS})
JOB_FAIL=$(cat ${FILE_FAIL})

#delete file descriptor
exec 6>&- #fd6
exec 7>&-
exec 8>&-
rm -f ${FILE_SUCCESS}
rm -f ${FILE_FAIL}

END_TS=$(date +"%s")
END_TIME=$(date +"%F %T")
cat <<EOF
############### Summary ###############
MAX_NPROC : ${MAX_NPROC}
DELAY_SEC : ${DELAY_SEC}
---------------------------------------
START_TIME: ${START_TIME}
END_TIME  : ${END_TIME}
DURATION  : $((END_TS - START_TS)) (seconds)
---------------------------------------
TOTAL_FULL     : ${TOTAL_FULL}
TOTAL_TOFETCH  : ${TOTAL_TOFETCH}
SKIP           : ${SKIP}

JOB_TOTAL      : ${JOB_TOTAL}
JOB_SUCCESS    : ${JOB_SUCCESS}
JOB_FAIL       : ${JOB_FAIL}
#######################################
EOF

echo "done!"