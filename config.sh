#!/bin/bash
U=("student01" "student02" "student03" "mentor")

for user in "${U[@]}"
do
  TOKEN=$(kubectl create token $U -n ns$U --duration=24h)
  SERVER=$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}')
  CA=$(kubectl config view --minify --raw -o jsonpath='{.clusters[0].cluster.certificate-authority-data}')
  
  cat > $user.kubeconfig <<EOF
apiVersion: v1
kind: Config
clusters:
- name: cluster
  cluster:
    server: ${SERVER}
    certificate-authority-data: ${CA}
users:
- name: ${user}
  user:
    token: ${TOKEN}
contexts:
- name: ${user}
  context:
    cluster: cluster
    user: ${user}
    namespace: ns${user}
current-context: ${user}
EOF
done
