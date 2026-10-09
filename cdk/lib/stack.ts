import * as cdk from "aws-cdk-lib";
import { Construct } from "constructs";
import * as ec2 from "aws-cdk-lib/aws-ec2";
import * as ecs from "aws-cdk-lib/aws-ecs";
import * as ecsPatterns from "aws-cdk-lib/aws-ecs-patterns";
import * as elasticache from "aws-cdk-lib/aws-elasticache";
import * as rds from "aws-cdk-lib/aws-rds";
import * as sqs from "aws-cdk-lib/aws-sqs";
import * as cloudfront from "aws-cdk-lib/aws-cloudfront";
import * as origins from "aws-cdk-lib/aws-cloudfront-origins";
import * as wafv2 from "aws-cdk-lib/aws-wafv2";
import * as appscaling from "aws-cdk-lib/aws-applicationautoscaling";

interface Props extends cdk.StackProps { appImage: string; }

export class MillionCcuStack extends cdk.Stack {
  constructor(scope: Construct, id: string, props: Props) {
    super(scope, id, props);

    // ── VPC ──────────────────────────────────────────
    const vpc = new ec2.Vpc(this, "Vpc", {
      maxAzs: 2,
      natGateways: 1,
      subnetConfiguration: [
        { name: "pub",  subnetType: ec2.SubnetType.PUBLIC,           cidrMask: 24 },
        { name: "prv",  subnetType: ec2.SubnetType.PRIVATE_WITH_EGRESS, cidrMask: 24 },
      ],
    });

    // ── WAF (CLOUDFRONT scope → us-east-1 not required in same stack with CF) ──
    const waf = new wafv2.CfnWebACL(this, "Waf", {
      scope: "CLOUDFRONT",
      defaultAction: { allow: {} },
      visibilityConfig: { cloudWatchMetricsEnabled: true, metricName: "MillionWaf", sampledRequestsEnabled: true },
      rules: [
        {
          name: "AWSCommon", priority: 1, overrideAction: { none: {} },
          statement: { managedRuleGroupStatement: { vendorName: "AWS", name: "AWSManagedRulesCommonRuleSet" } },
          visibilityConfig: { cloudWatchMetricsEnabled: true, metricName: "AWSCommon", sampledRequestsEnabled: true },
        },
        {
          name: "RateLimit", priority: 2, action: { block: {} },
          statement: { rateBasedStatement: { limit: 10000, aggregateKeyType: "IP" } },
          visibilityConfig: { cloudWatchMetricsEnabled: true, metricName: "RateLimit", sampledRequestsEnabled: true },
        },
      ],
    });

    // ── ECS Fargate + ALB (L3 Construct) ─────────────
    const cluster = new ecs.Cluster(this, "Cluster", { vpc, containerInsights: true });

    const fargateService = new ecsPatterns.ApplicationLoadBalancedFargateService(this, "FargateSvc", {
      cluster,
      cpu: 1024,
      memoryLimitMiB: 2048,
      desiredCount: 2,
      taskImageOptions: {
        image: ecs.ContainerImage.fromRegistry(props.appImage),
        containerPort: 8080,
      },
      publicLoadBalancer: true,
      assignPublicIp: false,
    });
    fargateService.targetGroup.configureHealthCheck({ path: "/health", interval: cdk.Duration.seconds(15), healthyThresholdCount: 2 });

    // Auto Scaling
    const scaling = fargateService.service.autoScaleTaskCount({ minCapacity: 2, maxCapacity: 200 });
    scaling.scaleOnCpuUtilization("CpuScaling", {
      targetUtilizationPercent: 70,
      scaleInCooldown: cdk.Duration.seconds(60),
      scaleOutCooldown: cdk.Duration.seconds(30),
    });

    // ── SQS ──────────────────────────────────────────
    const queue = new sqs.Queue(this, "Queue", {
      encryption: sqs.QueueEncryption.SQS_MANAGED,
      visibilityTimeout: cdk.Duration.seconds(300),
    });
    queue.grantSendMessages(fargateService.taskDefinition.taskRole);

    // ── ElastiCache Redis (CfnReplicationGroup) ───────
    const cacheSubnetGroup = new elasticache.CfnSubnetGroup(this, "CacheSubnet", {
      description: "Redis subnet group",
      subnetIds: vpc.privateSubnets.map(s => s.subnetId),
    });
    const cacheSg = new ec2.SecurityGroup(this, "CacheSg", { vpc, description: "Redis SG" });
    cacheSg.addIngressRule(fargateService.service.connections.securityGroups[0], ec2.Port.tcp(6379));
    new elasticache.CfnReplicationGroup(this, "Redis", {
      replicationGroupDescription: "Redis cluster",
      numCacheClusters: 2,
      cacheNodeType: "cache.r7g.large",
      automaticFailoverEnabled: true,
      atRestEncryptionEnabled: true,
      transitEncryptionEnabled: true,
      cacheSubnetGroupName: cacheSubnetGroup.ref,
      securityGroupIds: [cacheSg.securityGroupId],
    });

    // ── Aurora Serverless v2 ──────────────────────────
    const dbSg = new ec2.SecurityGroup(this, "DbSg", { vpc, description: "Aurora SG" });
    dbSg.addIngressRule(fargateService.service.connections.securityGroups[0], ec2.Port.tcp(5432));
    const aurora = new rds.DatabaseCluster(this, "Aurora", {
      engine: rds.DatabaseClusterEngine.auroraPostgres({ version: rds.AuroraPostgresEngineVersion.VER_15_4 }),
      serverlessV2MinCapacity: 0.5,
      serverlessV2MaxCapacity: 128,
      writer: rds.ClusterInstance.serverlessV2("writer"),
      readers: [
        rds.ClusterInstance.serverlessV2("reader1", { scaleWithWriter: true }),
        rds.ClusterInstance.serverlessV2("reader2", { scaleWithWriter: true }),
      ],
      vpc,
      vpcSubnets: { subnetType: ec2.SubnetType.PRIVATE_WITH_EGRESS },
      securityGroups: [dbSg],
      storageEncrypted: true,
    });

    // ── CloudFront (Micro-caching TTL=5s) ────────────
    const cf = new cloudfront.Distribution(this, "Cdn", {
      webAclId: waf.attrArn,
      defaultBehavior: {
        origin: new origins.LoadBalancerV2Origin(fargateService.loadBalancer, { protocolPolicy: cloudfront.OriginProtocolPolicy.HTTP_ONLY }),
        viewerProtocolPolicy: cloudfront.ViewerProtocolPolicy.REDIRECT_TO_HTTPS,
        cachePolicy: new cloudfront.CachePolicy(this, "MicroCache", {
          defaultTtl: cdk.Duration.seconds(5),
          maxTtl: cdk.Duration.seconds(30),
          minTtl: cdk.Duration.seconds(0),
        }),
        allowedMethods: cloudfront.AllowedMethods.ALLOW_ALL,
      },
    });

    // ── Outputs ───────────────────────────────────────
    new cdk.CfnOutput(this, "CloudFrontDomain", { value: cf.distributionDomainName });
    new cdk.CfnOutput(this, "AlbDns",           { value: fargateService.loadBalancer.loadBalancerDnsName });
    new cdk.CfnOutput(this, "AuroraWriter",      { value: aurora.clusterEndpoint.hostname });
    new cdk.CfnOutput(this, "AuroraReader",      { value: aurora.clusterReadEndpoint.hostname });
    new cdk.CfnOutput(this, "SqsQueueUrl",       { value: queue.queueUrl });
  }
}