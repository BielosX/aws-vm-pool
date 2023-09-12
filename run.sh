#!/bin/bash -e

export AWS_REGION="eu-west-1"

function get_in_service_instances() {
  instances=$(aws autoscaling describe-auto-scaling-groups \
    --auto-scaling-group-names "$1" \
    | jq -r '.AutoScalingGroups[0].Instances | map(select(.LifecycleState=="InService"))')
}

function tag_instances() {
  instance_ids=$(jq -r 'map(.InstanceId)' <<< "$1")
  length=$(jq -r 'length' <<< "$instance_ids")
  for i in $(seq 1 "$length"); do
    index=$(( i - 1 ))
    instance_id=$(jq --argjson id "$index" -r '.[$id]' <<< "$instance_ids")
    aws ec2 create-tags --resources "$instance_id" --tags "Key=Name,Value=vm${i}"
  done
}

function deploy() {
  pushd infra
  terraform init && terraform apply -auto-approve
  asg_name=$(terraform output -raw asg-name)
  desired_capacity=$(aws autoscaling describe-auto-scaling-groups \
    --auto-scaling-group-names "$asg_name" | jq -r '.AutoScalingGroups[0].DesiredCapacity')
  get_in_service_instances "$asg_name"
  count=$(jq -r 'length' <<< "$instances")
  while (( count < desired_capacity )); do
    echo "DesiredCapacity: ${desired_capacity} InService: ${count}"
    sleep 10
  done
  tag_instances "$instances"
  popd infra
}

function destroy() {
  pushd infra
  terraform destroy -auto-approve
  popd
}

function session() {
  instance_name="$1"
filters=$(cat << EOM
[
  {
    "Name": "instance-state-name",
    "Values": ["running"]
  },
  {
    "Name": "tag:Name",
    "Values": ["$instance_name"]
  }
]
EOM
)
  instance_id=$(aws ec2 describe-instances \
    --filters "$filters" | jq -r '.Reservations[0].Instances[0].InstanceId')
  aws ssm start-session --target "$instance_id" \
    --parameters command="/bin/zsh" \
    --document-name AWS-StartInteractiveCommand
}

case "$1" in
  "deploy")  deploy ;;
  "destroy") destroy ;;
  "session") session "$2" ;;
esac