#!/usr/bin/env node
import "source-map-support/register";
import * as cdk from "aws-cdk-lib";
import { MillionCcuStack } from "../lib/stack";

const app = new cdk.App();

new MillionCcuStack(app, "MillionCcuStack", {
  env: {
    account: process.env.CDK_DEFAULT_ACCOUNT,
    region: process.env.CDK_DEFAULT_REGION ?? "ap-northeast-1",
  },
  appImage: app.node.tryGetContext("appImage") ?? "public.ecr.aws/nginx/nginx:latest",
});