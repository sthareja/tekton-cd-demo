#!/bin/bash

set -e -u -o pipefail
declare -r SCRIPT_DIR=$(cd -P $(dirname $0) && pwd)
declare PRJ_PREFIX="demo"
declare COMMAND="help"
declare CONFIG_BASE_URL=https://raw.githubusercontent.com/siamaksade/spring-petclinic-config

valid_command() {
  local fn=$1; shift
  [[ $(type -t "$fn") == "function" ]]
}

info() {
    printf "\n# INFO: $@\n"
}

err() {
  printf "\n# ERROR: $1\n"
  exit 1
}

while (( "$#" )); do
  case "$1" in
    install|uninstall|start)
      COMMAND=$1
      shift
      ;;
    -p|--project-prefix)
      PRJ_PREFIX=$2
      shift 2
      ;;
    --)
      shift
      break
      ;;
    -*|--*)
      err "Error: Unsupported flag $1"
      ;;
    *) 
      break
  esac
done

declare -r dev_prj="$PRJ_PREFIX-dev"
declare -r stage_prj="$PRJ_PREFIX-stage"
declare -r cicd_prj="$PRJ_PREFIX-cicd"

command.help() {
  cat <<-EOF

  Usage:
      demo [command] [options]
  
  Example:
      demo install --project-prefix mydemo
  
  COMMANDS:
      install                        Sets up the demo and creates namespaces
      uninstall                      Deletes the demo namespaces
      start                          Starts the demo pipeline
      help                           Help about this command

  OPTIONS:
      -p|--project-prefix [string]   Prefix to be added to demo project names e.g. PREFIX-dev
EOF
}

command.install() {
  oc version >/dev/null 2>&1 || err "no oc binary found"

  info "Creating namespaces $cicd_prj, $dev_prj, $stage_prj"
  oc get ns $cicd_prj 2>/dev/null  || { 
    oc new-project $cicd_prj 
  }
  oc get ns $dev_prj 2>/dev/null  || { 
    oc new-project $dev_prj
  }
  oc get ns $stage_prj 2>/dev/null  || { 
    oc new-project $stage_prj 
  }

  info "Configure service account permissions for pipeline"
  oc policy add-role-to-user edit system:serviceaccount:$cicd_prj:pipeline -n $dev_prj
  oc policy add-role-to-user edit system:serviceaccount:$cicd_prj:pipeline -n $stage_prj

  info "Deploying CI/CD infra to $cicd_prj namespace"
  oc apply -f cd -n $cicd_prj
  GOGS_HOSTNAME=$(oc get route gogs -o template --template='{{.spec.host}}' -n $cicd_prj)

  info "Deploying pipeline and tasks to $cicd_prj namespace"
  oc apply -f tasks -n $cicd_prj
  oc apply -f config/maven-configmap.yaml -n $cicd_prj
  oc apply -f pipelines/pipeline-pvc.yaml -n $cicd_prj
  oc apply -f pipelines/petclinic-tests-git-resource.yaml -n $cicd_prj
  info "Apply Done"
  sed "s/demo-dev/$dev_prj/g" pipelines/pipeline-deploy-dev.yaml | oc apply -f - -n $cicd_prj
  sed "s/demo-dev/$dev_prj/g" pipelines/pipeline-deploy-stage.yaml | sed -E "s/demo-stage/$stage_prj/g" | oc apply -f - -n $cicd_prj
  sed "s/demo-dev/$dev_prj/g" pipelines/petclinic-image-resource.yaml | oc apply -f - -n $cicd_prj
  info "Stage 1 Done"
  sed "s#https://github.com/siamaksade/spring-petclinic#http://$GOGS_HOSTNAME/gogs/spring-petclinic.git#g" pipelines/petclinic-git-resource.yaml | oc apply -f - -n $cicd_prj
  info "Stage 2 Done"
  sed "s#https://github.com/siamaksade/spring-petclinic-config#http://$GOGS_HOSTNAME/gogs/spring-petclinic-config.git#g" pipelines/petclinic-config-git-resource.yaml | oc apply -f - -n $cicd_prj
  info "Stage 3 Done"
  sed "s#https://github.com/siamaksade/spring-petclinic-gatling#http://$GOGS_HOSTNAME/gogs/spring-petclinic-gatling.git#g" pipelines/petclinic-tests-git-resource.yaml | oc apply -f - -n $cicd_prj
  info "Stage 4 Done"

  
  oc apply -f triggers/gogs-triggerbinding.yaml -n $cicd_prj
  info "Stage 5 Done"
  oc apply -f triggers/triggertemplate.yaml -n $cicd_prj
  info "Stage 6 Done"
  sed "s/demo-dev/$dev_prj/g" triggers/eventlistener.yaml | oc apply -f - -n $cicd_prj
  info "Stage 7 Done"

  info "Initiatlizing git repository in Gogs and configuring webhooks"
  sed "s/@HOSTNAME/$GOGS_HOSTNAME/g" config/gogs-configmap.yaml | oc create -f - -n $cicd_prj
  oc rollout status deployment/gogs -n $cicd_prj
  oc create -f config/gogs-init-taskrun.yaml -n $cicd_prj

  oc project $cicd_prj

  cat <<-EOF

############################################################################
############################################################################

  Demo is installed! Give it a few minutes to finish deployments and then:

  1) Go to spring-petclinic Git repository in Gogs:
     http://$GOGS_HOSTNAME/gogs/spring-petclinic.git
  
  2) Log into Gogs with username/password: gogs/gogs
      
  3) Edit a file in the repository and commit to trigger the pipeline

  4) Check the pipeline run logs in Dev Console or Tekton CLI:
     
    \$ tkn pipeline logs petclinic-deploy-dev -f -n $cicd_prj

  
  You can find further details at:
  
  Gogs Git Server: http://$GOGS_HOSTNAME/explore/repos
  PipelineRun Reports: http://$(oc get route reports-repo -o template --template='{{.spec.host}}' -n $cicd_prj)
  SonarQube: https://$(oc get route sonarqube -o template --template='{{.spec.host}}' -n $cicd_prj)
  Sonatype Nexus: http://$(oc get route nexus -o template --template='{{.spec.host}}' -n $cicd_prj)

############################################################################
############################################################################
EOF
}

command.start() {
  oc create -f runs/pipeline-deploy-dev-run.yaml -n $cicd_prj
}

command.uninstall() {
  oc delete project $dev_prj $stage_prj $cicd_prj
}

main() {
  local fn="command.$COMMAND"
  valid_command "$fn" || {
    err "invalid command '$COMMAND'"
  }

  cd $SCRIPT_DIR
  $fn
  return $?
}

main
