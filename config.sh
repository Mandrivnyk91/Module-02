U=student01
NS=nsstudent01
TOKEN=$(kubectl create token $U -n $NS --duration=24h)
SERVER=$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}')
CA=$(kubectl config view --minify --raw -o jsonpath='{.clusters[0].cluster.certificate-authority-data}')

cat > $U.kubeconfig <<EOF
apiVersion: v1
kind: Config
clusters:
- name: cluster
  cluster:
    server: ${SERVER}
    certificate-authority-data: ${CA}
users:
- name: ${U}
  user:
    token: ${TOKEN}
contexts:
- name: ${U}
  context:
    cluster: cluster
    user: ${U}
    namespace: ${NS}
current-context: ${U}
EOF