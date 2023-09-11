#!/bin/bash -xe

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

case "$1" in
  "deploy")  deploy ;;
  "destroy") destroy ;;
esac