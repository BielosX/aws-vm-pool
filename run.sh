#!/bin/bash -xe

export AWS_REGION="eu-west-1"

function deploy() {
  pushd infra
  terraform init && terraform apply -auto-approve
  popd infra
}

function destroy() {
  pushd infra
  terraform destroy -auto-approve
  popd
}

function session() {
  aws ssm start-session --target "$1" \
    --parameters command="/bin/zsh" \
    --document-name AWS-StartInteractiveCommand
}

case "$1" in
  "deploy")  deploy ;;
  "destroy") destroy ;;
  "session") session "$2" ;;
esac