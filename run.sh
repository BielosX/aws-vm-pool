#!/bin/bash -e

export AWS_REGION="eu-west-1"
export AWS_PAGER=""

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

function get_private_instance_ip() {
  instance_id="$1"
  private_ip=$(aws ec2 describe-instances --instance-ids "$instance_id" \
    | jq -r '.Reservations[0].Instances[0].PrivateIpAddress')
}

function label_instance() {
  index="$2"
  instance_number=$(( index + 1 ))
  instance_name="vm${instance_number}"
  aws ec2 create-tags --resources "$1" --tags "Key=Name,Value=${instance_name}"
  get_private_instance_ip "$1"
change_batch=$(cat <<- EOM
{
  "Changes": [
    {
      "Action": "CREATE",
      "ResourceRecordSet": {
        "Name": "${instance_name}.local.",
        "Type": "A",
        "TTL": 10,
        "ResourceRecords": [
          {
            "Value": "$private_ip"
          }
        ]
      }
    }
  ]
}
EOM
)
  aws route53 change-resource-record-sets --hosted-zone-id "$hosted_zone_id" --change-batch "$change_batch"
}

function label_instances() {
  for_every_instance "$1" label_instance
}

function check_instance_status() {
  instance_id="$1"
  tags=$(aws ec2 describe-tags --filters "Name=resource-id,Values=$instance_id" \
           | jq -r '.Tags | map(select(.Key == "ready" and .Value == "true"))')
  echo "instance ${instance_id} status tag: ${tags}"
  local length
  length=$(jq -r 'length' <<< "$tags")
  if (( length > 0 )); then
    instances_ready=$(( instances_ready + 1 ))
    echo "instance ${instance_id} ready"
  fi
}

function verify_status() {
  instances_ready=0
  for_every_instance "$1" check_instance_status
}

function wait_for_all() {
  local length
  length=$(jq -r 'length' <<< "$1")
  echo "Waiting for ${length} instances"
  verify_status "$1"
  echo "${instances_ready} of ${length} are ready"
  while (( instances_ready < length )); do
    echo "${instances_ready} of ${length} are ready"
    sleep 10
    verify_status "$1"
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
  hosted_zone_id=$(terraform output -raw hosted-zone-id)
  desired_capacity=$(aws autoscaling describe-auto-scaling-groups \
    --auto-scaling-group-names "$asg_name" | jq -r '.AutoScalingGroups[0].DesiredCapacity')
  get_in_service_instances "$asg_name"
  count=$(jq -r 'length' <<< "$instances")
  while (( count < desired_capacity )); do
    echo "DesiredCapacity: ${desired_capacity} InService: ${count}"
    sleep 10
  done
  label_instances "$instances"
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

function remove_dns_entries() {
  records=$(aws route53 list-resource-record-sets --hosted-zone-id "$hosted_zone_id" \
    | jq -r '.ResourceRecordSets | map(select(.Type == "A"))')
  length=$(jq -r 'length' <<< "$records")
  for i in $(seq 1 "$length"); do
    index=$(( i - 1 ))
    record=$(jq --argjson id "$index" -r '.[$id]' <<< "$records")
    name=$(jq -r '.Name' <<< "$record")
    value=$(jq -r '.ResourceRecords[0].Value' <<< "$record")
    echo "Removing DNS entry ${name}: ${value}"
change_batch=$(cat <<- EOM
{
 "Changes": [
   {
     "Action": "DELETE",
     "ResourceRecordSet": {
       "Name": "$name",
       "Type": "A",
       "TTL": 10,
       "ResourceRecords": [
         {
           "Value": "$value"
         }
       ]
     }
   }
 ]
}
EOM
)
  aws route53 change-resource-record-sets --hosted-zone-id "$hosted_zone_id" --change-batch "$change_batch"
  done
}

function refresh_instances() {
  pushd infra
  asg_name=$(terraform output -raw asg-name)
  hosted_zone_id=$(terraform output -raw hosted-zone-id)
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
  remove_dns_entries
  get_in_service_instances "$asg_name"
  label_instances "$instances"
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