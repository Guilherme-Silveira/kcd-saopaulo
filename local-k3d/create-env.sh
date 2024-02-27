#!/bin/bash

## Create Kubernetes cluster
k3d cluster create --agents 2 -p 80:30000 -p 443:30001 --k3s-node-label "type=data@agent:0" --k3s-node-label "type=ml@agent:1"

# Install Ingress
kubectl apply -f ingress-controller.yaml

# Install ECK CRDS and Operator
kubectl apply -f crds.yaml; kubectl apply -f operator.yaml

# Install Elasticsearch
kubectl apply -f es.yaml

# Install Enterprise Search
kubectl apply -f ent-search.yaml

# Install Kibana
kubectl apply -f kibana.yaml

# Apply trial license
kubectl apply -f license.yaml

# Create CA secret
kubectl create secret generic elastic-ca --from-file=tls.crt=ca.pem --from-file=tls.key=ca.key

# Install Cert Manager
kubectl apply -f cert-manager.yaml

# Configure ECK Autoscaling
kubectl apply -f autoscaling.yaml

sleep 150

# Configure Cluster Issuer
kubectl apply -f cluster-issuer.yaml

# Configure Certificates
kubectl apply -f certificate.yaml

sleep 150

# Configure Jupyter
kubectl apply -f jupyter.yaml

sleep 150

# Create openai secret
kubectl create secret generic openai --from-literal=api=$1

# Create App
kubectl apply -f app.yaml

# Create Locust
kubectl apply -f locust.yaml

sleep 300

# Configure Ingress
kubectl apply -f ingress.yaml