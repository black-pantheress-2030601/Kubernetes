#!/bin/bash
export PATH="/opt/homebrew/bin:$PATH"
export AWS_PROFILE=SandboxWC
/opt/homebrew/bin/aws eks get-token --cluster-name downstream-cluster --region us-east-1 --output json | sed 's/client.authentication.k8s.io\/v1beta1/client.authentication.k8s.io\/v1/'
