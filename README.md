# aws-vm-pool

Create AWS EC2 auto-scaling-group with specified number of instances for GNU/Linux experiments.
Instances can be accessed using `ssm-agent`.

## Usage

Deploy AWS infrastructure:
```shell
./run deploy
```

Default number of instances is `1` and instanceType `t3.micro`. Used Linux distribution is `Amazon Linux 2023`.
Region is `eu-west-1`.
To change number of instances and instanceType use:
```shell
./run deploy --instances 5 --instance-type "t3.medium"
```

Destroy infrastructure:
```shell
./run destroy
```

Instances are tagged with `Name: vm${i}` where `i` is in range `1` to `instances`.
Instance with `Name: vm1` can be accessed with:

```shell
./run session vm1
```

Auto Scaling Group can be refreshed (Replace all instances) with:
```shell
./run refresh
```

Every instance is registered in private `Route53` hosted zone, instance is available as `vm${index}.local`
for example:
```shell
ping vm2.local
```

Will send ICMP packets to instance named `vm2`