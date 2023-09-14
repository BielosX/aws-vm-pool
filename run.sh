#!/bin/bash -e

export AWS_REGION="eu-west-1"

function get_in_service_instances() {
  instances=$(aws autoscaling describe-auto-scaling-groups \
    --auto-scaling-group-names "$1" \
    | jq -r '.AutoScalingGroups[0].Instances | map(select(.LifecycleState=="InService"))')
}

function for_every_instance() {
  instance_ids=$(jq -r 'map(.InstanceId)' <<< "$1")
  length=$(jq -r 'length' <<< "$instance_ids")
  for i in $(seq 1 "$length"); do
    index=$(( i - 1 ))
    instance_id=$(jq --argjson id "$index" -r '.[$id]' <<< "$instance_ids")
    $2 "$instance_id" "$index"
  done
}

function tag_instance() {
  index="$2"
  instance_number=$(( index + 1 ))
  aws ec2 create-tags --resources "$1" --tags "Key=Name,Value=vm${instance_number}"
}

function tag_instances() {
  for_every_instance "$1" tag_instance
}

function check_instance_status() {
  instance_id="$1"
  tags=$(aws ec2 describe-tags --filters "Name=resource-id,Values=$instance_id" \
           | jq -r '.Tags | map(select(.Key == "ready" and .Value == "true"))')
  echo "instance ${instance_id} status tag: ${tags}"
  length=$(jq -r 'length' <<< "$tags")
  if (( length > 0 )); then
    instances_status+=(true)
  else
    instances_status+=(false)
  fi
}

function count_true() {
  array=("$@")
  true_values=0
  for i in "${array[@]}"; do
    if [ "$1" == true ]; then
      true_values=$(( true_values + 1 ))
    fi
  done
}

function verify_status() {
  instances_status=()
  for_every_instance "$1" check_instance_status
  count_true "${instances_status[@]}"
}

function wait_for_all() {
  length=$(jq -r 'length' <<< "$1")
  verify_status "$1"
  while (( true_values < length )); do
    verify_status "$1"
    echo "${true_values} of ${length} are ready"
    sleep 10
  done
  echo "All instances are ready"
}

function deploy() {
  local instance_count="${1:-1}"
  local instance_type="${2:-t3.micro}"
  pushd infra
  terraform init && terraform apply -auto-approve \
    -var="number-of-instances=$instance_count" -var="instance-type=$instance_type"
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
  wait_for_all "$instances"
  popd infra
}

function destroy() {
  pushd infra
  terraform destroy -auto-approve
  popd
}

function session() {
  instance_name="$1"
filters=$(cat <<- EOM
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

function get_refresh_status() {
   status=$(aws autoscaling describe-instance-refreshes \
       --auto-scaling-group-name "$1" \
       --instance-refresh-ids "$2" | jq -r '.InstanceRefreshes[0].Status')
}

function refresh_instances() {
  pushd infra
  asg_name=$(terraform output -raw asg-name)
  refresh_id=$(aws autoscaling start-instance-refresh \
    --auto-scaling-group-name "$asg_name" \
    --strategy "Rolling" \
    --preferences "MinHealthyPercentage=0,InstanceWarmup=30" | jq -r '.InstanceRefreshId')
  get_refresh_status "$asg_name" "$refresh_id"
  while [ "$status" = "Pending" ] || [ "$status" = "InProgress" ]; do
    echo "Status: ${status}"
    get_refresh_status "$asg_name" "$refresh_id"
    sleep 10
  done
  get_in_service_instances "$asg_name"
  tag_instances "$instances"
  wait_for_all "$instances"
  popd
}

POSITIONAL_ARGS=()

number_of_args="$#"
while (( number_of_args > 0 )); do
  case "$1" in
    "--instances")
      INSTANCES="$2"
      shift
      shift
      ;;
    "--instance-type")
      TYPE="$2"
      shift
      shift
      ;;
    *)
      POSITIONAL_ARGS+=("$1")
      shift
      ;;
  esac
  number_of_args="$#"
done

# Positional args become $1 $2 etc
set -- "${POSITIONAL_ARGS[@]}"

case "$1" in
  "deploy")  deploy "$INSTANCES" "$TYPE" ;;
  "destroy") destroy ;;
  "session") session "$2" ;;
  "refresh") refresh_instances ;;
esac