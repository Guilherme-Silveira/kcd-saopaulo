data "google_client_config" "current" {}

resource "google_container_cluster" "_" {
  name     = local.name
  location = local.region

  deletion_protection = false

  node_pool {
    name = "builtin"
  }
  lifecycle {
    ignore_changes = [node_pool]
  }
}

resource "google_container_node_pool" "data" {
  name               = "data"
  cluster            = google_container_cluster._.id
  initial_node_count = 1

  node_config {
    preemptible  = false
    machine_type = "e2-standard-16"
    labels = {
      type = "data"
    }
  }
}

resource "google_container_node_pool" "ml" {
  name               = "ml"
  cluster            = google_container_cluster._.id
  initial_node_count = 1

  autoscaling {
    total_min_node_count = "1"
    total_max_node_count = "5"
  }

  node_config {
    preemptible  = true
    machine_type = "g2-standard-8"
    labels = {
      type = "ml"
    }
  }
}

resource "kubernetes_cluster_role_binding" "cluster-admin-binding" {
  metadata {
    name = "cluster role binding"
  }
  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ClusterRole"
    name      = "cluster-admin"
  }
  subject {
    kind      = "User"
    name      = var.email
    api_group = "rbac.authorization.k8s.io"
  }
  subject {
    kind      = "ServiceAccount"
    name      = "default"
    namespace = "kube-system"
  }
  subject {
    kind      = "Group"
    name      = "system:masters"
    api_group = "rbac.authorization.k8s.io"
  }

  depends_on = [google_container_cluster._, google_container_node_pool.data, google_container_node_pool.ml]
}

# Install ECK operator via helm-charts
resource "helm_release" "elastic" {
  name = "elastic-operator"

  repository       = "https://helm.elastic.co"
  chart            = "eck-operator"
  namespace        = "elastic-system"
  create_namespace = "true"

  depends_on = [google_container_cluster._, google_container_node_pool.data, google_container_node_pool.ml, kubernetes_cluster_role_binding.cluster-admin-binding]

}

resource "helm_release" "ingress_nginx" {
  name = "ingress-nginx"

  repository       = "https://kubernetes.github.io/ingress-nginx"
  chart            = "ingress-nginx"
  namespace        = "ingress-nginx"
  create_namespace = "true"

  depends_on = [google_container_cluster._, google_container_node_pool.data, google_container_node_pool.ml, kubernetes_cluster_role_binding.cluster-admin-binding]

}

resource "helm_release" "cert_manager" {
  name = "cert-manager"

  repository       = "https://charts.jetstack.io"
  chart            = "cert-manager"
  namespace        = "cert-manager"
  create_namespace = "true"
  set {
    name  = "installCRDs"
    value = "true"
  }

  depends_on = [google_container_cluster._, google_container_node_pool.data, google_container_node_pool.ml, kubernetes_cluster_role_binding.cluster-admin-binding]

}

resource "kubectl_manifest" "gpu_driver" {
  yaml_body  = <<YAML
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: nvidia-driver-installer
  namespace: kube-system
  labels:
    k8s-app: nvidia-driver-installer
spec:
  selector:
    matchLabels:
      k8s-app: nvidia-driver-installer
  updateStrategy:
    type: RollingUpdate
  template:
    metadata:
      labels:
        name: nvidia-driver-installer
        k8s-app: nvidia-driver-installer
    spec:
      priorityClassName: system-node-critical
      affinity:
        nodeAffinity:
          requiredDuringSchedulingIgnoredDuringExecution:
            nodeSelectorTerms:
            - matchExpressions:
              - key: cloud.google.com/gke-accelerator
                operator: Exists
              - key: cloud.google.com/gke-gpu-driver-version
                operator: DoesNotExist
      tolerations:
      - operator: "Exists"
      hostNetwork: true
      hostPID: true
      volumes:
      - name: dev
        hostPath:
          path: /dev
      - name: vulkan-icd-mount
        hostPath:
          path: /home/kubernetes/bin/nvidia/vulkan/icd.d
      - name: nvidia-install-dir-host
        hostPath:
          path: /home/kubernetes/bin/nvidia
      - name: root-mount
        hostPath:
          path: /
      - name: cos-tools
        hostPath:
          path: /var/lib/cos-tools
      - name: nvidia-config
        hostPath:
          path: /etc/nvidia
      initContainers:
      - image: "cos-nvidia-installer:fixed"
        imagePullPolicy: Never
        name: nvidia-driver-installer
        resources:
          requests:
            cpu: 150m
        securityContext:
          privileged: true
        env:
        - name: NVIDIA_INSTALL_DIR_HOST
          value: /home/kubernetes/bin/nvidia
        - name: NVIDIA_INSTALL_DIR_CONTAINER
          value: /usr/local/nvidia
        - name: VULKAN_ICD_DIR_HOST
          value: /home/kubernetes/bin/nvidia/vulkan/icd.d
        - name: VULKAN_ICD_DIR_CONTAINER
          value: /etc/vulkan/icd.d
        - name: ROOT_MOUNT_DIR
          value: /root
        - name: COS_TOOLS_DIR_HOST
          value: /var/lib/cos-tools
        - name: COS_TOOLS_DIR_CONTAINER
          value: /build/cos-tools
        volumeMounts:
        - name: nvidia-install-dir-host
          mountPath: /usr/local/nvidia
        - name: vulkan-icd-mount
          mountPath: /etc/vulkan/icd.d
        - name: dev
          mountPath: /dev
        - name: root-mount
          mountPath: /root
        - name: cos-tools
          mountPath: /build/cos-tools
        command:
        - bash
        - -c
        - | 
          echo "Checking for existing GPU driver modules"
          if lsmod | grep nvidia; then
            echo "GPU driver is already installed, the installed version may or may not be the driver version being tried to install, skipping installation"
            exit 0
          else
            echo "No GPU driver module detected, installting now"
            /cos-gpu-installer install --version=latest
            chmod 755 /root/home/kubernetes/bin/nvidia
          fi
      - image: "gcr.io/gke-release/nvidia-partition-gpu@sha256:e226275da6c45816959fe43cde907ee9a85c6a2aa8a429418a4cadef8ecdb86a"
        name: partition-gpus
        env:
          - name: LD_LIBRARY_PATH
            value: /usr/local/nvidia/lib64
        resources:
          requests:
            cpu: 150m
        securityContext:
          privileged: true
        volumeMounts:
        - name: nvidia-install-dir-host
          mountPath: /usr/local/nvidia
        - name: dev
          mountPath: /dev
        - name: nvidia-config
          mountPath: /etc/nvidia
      containers:
      - image: "gcr.io/google-containers/pause:2.0"
        name: pause
YAML
  depends_on = [helm_release.elastic]
}

# Create License manifest
resource "kubectl_manifest" "license_eck" {
  yaml_body  = <<YAML
apiVersion: v1
kind: Secret
metadata:
  name: eck-trial-license
  namespace: elastic-system
  labels:
    license.k8s.elastic.co/type: enterprise_trial
  annotations:
    elastic.co/eula: accepted 
YAML
  depends_on = [helm_release.elastic]
}

# Delay of 30s to wait until ECK operator is up and running
resource "time_sleep" "wait_30_seconds" {
  depends_on = [helm_release.elastic]

  create_duration = "30s"
}

# Create Elasticsearch cluster
resource "kubectl_manifest" "elastic_vector" {
  yaml_body = <<YAML
apiVersion: elasticsearch.k8s.elastic.co/v1
kind: Elasticsearch
metadata:
  name: vector
spec:
  version: 8.11.4
  monitoring:
    metrics:
      elasticsearchRefs:
      - name: vector
    logs:
      elasticsearchRefs:
      - name: vector
  nodeSets:
  - name: default
    count: 3
    config:
      node.roles: [ data_hot, data_content, ingest, master, remote_cluster_client ]
      node.store.allow_mmap: false
    volumeClaimTemplates:
    - metadata:
        name: elasticsearch-data
      spec:
        accessModes:
        - ReadWriteOnce
        resources:
          requests:
            storage: 100Gi
        storageClassName: premium-rwo
    podTemplate:
      spec:
        nodeSelector:
          type: data
        containers:
        - name: elasticsearch
          env:
          - name: ES_JAVA_OPTS
            value: -Xms16g -Xmx16g
          resources:
            requests:
              memory: 32Gi
            limits:
              memory: 32Gi
          readinessProbe:
            exec:
              command:
              - bash
              - -c
              - /mnt/elastic-internal/scripts/readiness-probe-script.sh
            failureThreshold: 3
            initialDelaySeconds: 10
            periodSeconds: 12
            successThreshold: 1
            timeoutSeconds: 12
  - name: ml
    count: 1
    config:
      node.roles: [ ml ]
      node.store.allow_mmap: false
    volumeClaimTemplates:
    - metadata:
        name: elasticsearch-data
      spec:
        accessModes:
        - ReadWriteOnce
        resources:
          requests:
            storage: 10Gi
        storageClassName: premium-rwo
    podTemplate:
      spec:
        nodeSelector:
          type: ml
        containers:
        - name: elasticsearch
          resources:
            requests:
              memory: 2Gi
            limits:
              memory: 4Gi
              nvidia.com/gpu: 1
          readinessProbe:
            exec:
              command:
              - bash
              - -c
              - /mnt/elastic-internal/scripts/readiness-probe-script.sh
            failureThreshold: 3
            initialDelaySeconds: 10
            periodSeconds: 12
            successThreshold: 1
            timeoutSeconds: 12
YAML

  provisioner "local-exec" {
    command = "sleep 60"
  }
  depends_on = [helm_release.elastic, time_sleep.wait_30_seconds]
}

# Create Enterprise Search Manifest
resource "kubectl_manifest" "enterprise_search_vector" {
  yaml_body = <<YAML
apiVersion: enterprisesearch.k8s.elastic.co/v1
kind: EnterpriseSearch
metadata:
  name: enterprise-search-vector
spec:
  version: 8.11.4
  count: 1
  elasticsearchRef:
    name: vector
  podTemplate:
    spec:
      containers:
      - name: enterprise-search
        resources:
          requests:
            cpu: 2
            memory: 4Gi
          limits:
            memory: 8Gi
        env:
        - name: JAVA_OPTS
          value: -Xms2048m -Xmx2048m
YAML

  provisioner "local-exec" {
    command = "sleep 30"
  }
  depends_on = [helm_release.elastic, kubectl_manifest.elastic_vector]
}

# Create Kibana manifest
resource "kubectl_manifest" "kibana_vector" {
  yaml_body = <<YAML
apiVersion: kibana.k8s.elastic.co/v1
kind: Kibana
metadata:
  name: vector
spec:
  version: 8.11.4
  count: 2
  config:
    monitoring.ui.ccs.enabled: false
  monitoring:
    metrics:
      elasticsearchRefs:
      - name: vector
    logs:
      elasticsearchRefs:
      - name: vector
  elasticsearchRef:
    name: vector
  enterpriseSearchRef:
    name: enterprise-search-vector
  podTemplate:
    spec:
      containers:
      - name: kibana
        env:
          - name: NODE_OPTIONS
            value: "--max-old-space-size=2048"
        resources:
          requests:
            memory: 1Gi
            cpu: 0.5
          limits:
            memory: 2.5Gi
            cpu: 2
YAML

  provisioner "local-exec" {
    command = "sleep 30"
  }
  depends_on = [helm_release.elastic, kubectl_manifest.elastic_vector, kubectl_manifest.enterprise_search_vector]
}

# Create Autoscaling manifest
resource "kubectl_manifest" "autoscaling_vector" {
  yaml_body  = <<YAML
apiVersion: autoscaling.k8s.elastic.co/v1alpha1
kind: ElasticsearchAutoscaler
metadata:
  name: autoscaling-vector
spec:
  elasticsearchRef:
    name: vector
  policies:
    - name: ml
      roles:
        - ml
      resources:
        nodeCount:
          min: 1
          max: 3
        cpu:
          min: 1
          max: 2
        memory:
          min: 2Gi
          max: 3Gi
        storage:
          min: 10Gi
          max: 10Gi
YAML
  depends_on = [helm_release.elastic, kubectl_manifest.elastic_vector]
}

# Create ClusterIssuer manifest
resource "kubectl_manifest" "cluster_issuer" {
  yaml_body = <<YAML
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-vector
spec:
  acme:
    email: ${var.email}
    server: https://acme-v02.api.letsencrypt.org/directory
    privateKeySecretRef:
      name: letsencrypt-vector
    solvers:
    - http01:
        ingress:
          class: nginx
YAML

  depends_on = [helm_release.cert_manager]
}

# Create Certificate manifest
resource "kubectl_manifest" "certificate" {
  yaml_body = <<YAML
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: letsencrypt-cert
spec:
  secretName: letsencrypt-cert
  dnsNames: [${join(", ", local.dns_names_yaml)}]
  issuerRef:
    name: letsencrypt-vector
    kind: ClusterIssuer
YAML

  depends_on = [helm_release.cert_manager, kubectl_manifest.cluster_issuer]
}

# Create Ingress manifest
resource "kubectl_manifest" "ingress_kibana" {
  yaml_body = <<YAML
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: kibana
  annotations:
    nginx.ingress.kubernetes.io/backend-protocol: HTTPS
    nginx.ingress.kubernetes.io/proxy-body-size: "4g"
    cert-manager.io/cluster-issuer: "letsencrypt-vector"
spec:
  ingressClassName: nginx
  tls:
  - hosts:
      - ${var.dns_names[1]}
    secretName: letsencrypt-cert
  rules:
    - host: ${var.dns_names[1]}
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: vector-kb-http
                port:
                  number: 5601
YAML

  depends_on = [helm_release.cert_manager, kubectl_manifest.cluster_issuer, kubectl_manifest.elastic_vector, kubectl_manifest.kibana_vector, helm_release.ingress_nginx]
}

resource "kubectl_manifest" "ingress_elasticsearch" {
  yaml_body = <<YAML
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: elasticsearch
  annotations:
    nginx.ingress.kubernetes.io/backend-protocol: HTTPS
    nginx.ingress.kubernetes.io/proxy-body-size: "4g"
    cert-manager.io/cluster-issuer: "letsencrypt-vector"
spec:
  ingressClassName: nginx
  tls:
  - hosts:
      - ${var.dns_names[0]}
    secretName: letsencrypt-cert
  rules:
    - host: ${var.dns_names[0]}
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: vector-es-http
                port:
                  number: 9200
YAML

  depends_on = [helm_release.cert_manager, kubectl_manifest.cluster_issuer, kubectl_manifest.elastic_vector, kubectl_manifest.kibana_vector, helm_release.ingress_nginx]
}

resource "kubectl_manifest" "jupyter_pvc" {
  yaml_body = <<YAML
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: jupyterlab-pvc
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 10Gi
YAML

  depends_on = [helm_release.cert_manager, kubectl_manifest.cluster_issuer, kubectl_manifest.elastic_vector, kubectl_manifest.kibana_vector, helm_release.ingress_nginx]
}

resource "kubectl_manifest" "jupyter_svc" {
  yaml_body = <<YAML
apiVersion: v1
kind: Service
metadata:
  name: jupyterlab
  labels:
    name: jupyterlab
spec:
  type: ClusterIP
  ports:
    - port: 8888
      targetPort: 8888
      protocol: TCP
      name: http
  selector:
    name: jupyterlab
YAML

  depends_on = [helm_release.cert_manager, kubectl_manifest.cluster_issuer, kubectl_manifest.elastic_vector, kubectl_manifest.kibana_vector, helm_release.ingress_nginx]
}

resource "kubectl_manifest" "jupyter" {
  yaml_body = <<YAML
apiVersion: apps/v1
kind: Deployment
metadata:
  name: jupyterlab
  labels:
    name: jupyterlab
spec:
  replicas: 1
  selector:
    matchLabels:
      name: jupyterlab
  template:
    metadata:
      labels:
        name: jupyterlab
    spec:
      securityContext:
        runAsUser: 0
        fsGroup: 0
      containers:
        - name: jupyterlab
          image: jupyter/datascience-notebook:latest
          imagePullPolicy: IfNotPresent
          env:
            - name: CHOWN_HOME
              value: "yes"
            - name: CHOWN_HOME_OPTS
              value: "-R"
            - name: ES_USER
              value: "elastic"
            - name: ES_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: vector-es-elastic-user
                  key: elastic
            - name: ES_URI
              value: "https://vector-es-http:9200"
          ports:
          - containerPort: 8888
          command:
            - /bin/bash
            - -c
            - |
              start.sh jupyter lab --LabApp.token='changeme' --LabApp.ip='0.0.0.0' --LabApp.allow_root=True
          volumeMounts:
            - name: jupyterlab-data
              mountPath: /home/jovyan
            - name: es-http-ca
              mountPath: /tmp/ca.crt
              subPath: tls.crt
          resources:
            requests:
              memory: 500Mi
              cpu: 250m
      restartPolicy: Always
      volumes:
      - name: jupyterlab-data
        persistentVolumeClaim:
          claimName: jupyterlab-pvc
      - name: es-http-ca
        secret:
          secretName: vector-es-http-ca-internal
YAML

  depends_on = [helm_release.cert_manager, kubectl_manifest.cluster_issuer, kubectl_manifest.elastic_vector, kubectl_manifest.kibana_vector, helm_release.ingress_nginx, kubectl_manifest.jupyter_pvc]
}

resource "kubectl_manifest" "ingress_jupyter" {
  yaml_body = <<YAML
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: jupyter
  annotations:
    cert-manager.io/cluster-issuer: "letsencrypt-vector"
spec:
  ingressClassName: nginx
  tls:
  - hosts:
      - ${var.dns_names[2]}
    secretName: letsencrypt-cert
  rules:
    - host: ${var.dns_names[2]}
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: jupyterlab
                port:
                  number: 8888
YAML

  depends_on = [helm_release.cert_manager, kubectl_manifest.cluster_issuer, kubectl_manifest.elastic_vector, kubectl_manifest.kibana_vector, helm_release.ingress_nginx, kubectl_manifest.jupyter]
}

# Create OpenAI Secret
resource "kubectl_manifest" "openai_secret" {
  yaml_body = <<YAML
apiVersion: v1
kind: Secret
metadata:
  name: openai
type: Opaque
data:
  api: ${var.openai_api}
YAML

  depends_on = [helm_release.cert_manager, kubectl_manifest.cluster_issuer, kubectl_manifest.elastic_vector, kubectl_manifest.kibana_vector, helm_release.ingress_nginx]
}

resource "kubectl_manifest" "app" {
  yaml_body = <<YAML
apiVersion: apps/v1
kind: Deployment
metadata:
  name: app
  labels:
    name: app
spec:
  replicas: 2
  selector:
    matchLabels:
      name: app
  template:
    metadata:
      labels:
        name: app
    spec:
      containers:
        - name: app
          image: guisilveira/elastic-docs-gpt:latest
          imagePullPolicy: IfNotPresent
          env:
            - name: ES_USER
              value: "elastic"
            - name: ES_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: vector-es-elastic-user
                  key: elastic
            - name: ES_URI
              value: "https://vector-es-http:9200"
            - name: LLM_API
              valueFrom:
                secretKeyRef:
                  name: openai
                  key: api
          ports:
          - containerPort: 8501
          volumeMounts:
            - name: es-http-ca
              mountPath: /tmp/ca.crt
              subPath: tls.crt
          resources:
            requests:
              memory: 500Mi
              cpu: 250m
      restartPolicy: Always
      volumes:
      - name: es-http-ca
        secret:
          secretName: vector-es-http-ca-internal
YAML

  depends_on = [helm_release.cert_manager, kubectl_manifest.cluster_issuer, kubectl_manifest.elastic_vector, kubectl_manifest.kibana_vector, helm_release.ingress_nginx, kubectl_manifest.openai_secret]
}

resource "kubectl_manifest" "app_svc" {
  yaml_body = <<YAML
apiVersion: v1
kind: Service
metadata:
  name: app
  labels:
    name: app
spec:
  type: ClusterIP
  ports:
    - port: 8501
      targetPort: 8501
      protocol: TCP
      name: http
  selector:
    name: app
YAML

  depends_on = [helm_release.cert_manager, kubectl_manifest.cluster_issuer, kubectl_manifest.elastic_vector, kubectl_manifest.kibana_vector, helm_release.ingress_nginx]
}

resource "kubectl_manifest" "ingress_app" {
  yaml_body = <<YAML
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: app
  annotations:
    cert-manager.io/cluster-issuer: "letsencrypt-vector"
spec:
  ingressClassName: nginx
  tls:
  - hosts:
      - ${var.dns_names[4]}
    secretName: letsencrypt-cert
  rules:
    - host: ${var.dns_names[4]}
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: app
                port:
                  number: 8501
YAML

  depends_on = [helm_release.cert_manager, kubectl_manifest.cluster_issuer, kubectl_manifest.elastic_vector, kubectl_manifest.kibana_vector, helm_release.ingress_nginx, kubectl_manifest.app]
}

resource "kubectl_manifest" "locustfile" {
  yaml_body = <<YAML
apiVersion: v1
kind: ConfigMap
metadata:
  name: scripts-cm
data:
  locustfile.py: |
    import os
    from locust import HttpUser, task, between
    from requests.auth import HTTPBasicAuth

    class ElasticsearchUser(HttpUser):
        wait_time = between(1, 2)  # Time between tasks for each user

        es_pass = os.environ['ES_PASSWORD']
        es_user = os.environ['ES_USER']

        @task
        def perform_query(self):
            query = {
                "query": {
                    "bool": {
                    "must": [
                        {
                        "match": {
                            "title": {
                            "query": "How to configure an Ingress on Kubernetes",
                            "boost": 1
                            }
                        }
                        }
                    ],
                    "filter": [
                        {
                        "exists": {
                            "field": "ml.inference.title-vector.predicted_value"
                        }
                        }
                    ]
                    }
                },
                "knn": {
                    "field": "ml.inference.title-vector.predicted_value",
                    "k": 1,
                    "num_candidates": 20,
                    "query_vector_builder": {
                    "text_embedding": {
                        "model_id": "sentence-transformers__all-distilroberta-v1",
                        "model_text": "How to configure an Ingress on Kubernetes"
                    }
                    },
                    "boost": 24
                },
                "fields": [
                    "title",
                    "body_content",
                    "url"
                ],
                "_source": [],
                "size": 1
                }
            index = 'search-elastic-docs'
            headers = {"Content-Type": "application/json"}
            auth = HTTPBasicAuth(self.es_user, self.es_pass)
            custom_ca='/tmp/ca.crt'
            self.client.post(f"/{index}/_search", json=query, headers=headers, auth=auth, verify=custom_ca)
YAML

  depends_on = [helm_release.cert_manager, kubectl_manifest.cluster_issuer, kubectl_manifest.elastic_vector, kubectl_manifest.kibana_vector, helm_release.ingress_nginx]
}

resource "kubectl_manifest" "locust_master" {
  yaml_body = <<YAML
apiVersion: apps/v1
kind: Deployment
metadata:
  annotations:
    deployment.kubernetes.io/revision: "1"
  labels:
    role: locust-master
    app: locust-master
  name: locust-master
spec:
  replicas: 1
  selector:
    matchLabels:
      role: locust-master
      app: locust-master
  strategy:
    rollingUpdate:
      maxSurge: 1
      maxUnavailable: 1
    type: RollingUpdate
  template:
    metadata:
      labels:
        role: locust-master
        app: locust-master
    spec:
      containers:
      - image: guisilveira/locust:elastic
        imagePullPolicy: Always
        name: master
        args: ["--master"]
        env:
          - name: ES_USER
            value: "elastic"
          - name: ES_PASSWORD
            valueFrom:
              secretKeyRef:
                name: vector-es-elastic-user
                key: elastic
          - name: ES_URI
            value: "https://vector-es-http:9200"
        volumeMounts:
          - mountPath: /home/locust
            name: locust-scripts
          - name: es-http-ca
            mountPath: /tmp/ca.crt
            subPath: tls.crt
        ports:
        - containerPort: 5557
          name: comm
        - containerPort: 5558
          name: comm-plus-1
        - containerPort: 8089
          name: web-ui
        resources: {}
        terminationMessagePath: /dev/termination-log
        terminationMessagePolicy: File
      dnsPolicy: ClusterFirst
      restartPolicy: Always
      schedulerName: default-scheduler
      securityContext: {}
      terminationGracePeriodSeconds: 30
      volumes:
      - name: locust-scripts
        configMap:
          name: scripts-cm
      - name: es-http-ca
        secret:
          secretName: vector-es-http-ca-internal
YAML

  depends_on = [helm_release.cert_manager, kubectl_manifest.cluster_issuer, kubectl_manifest.elastic_vector, kubectl_manifest.kibana_vector, helm_release.ingress_nginx]
}

resource "kubectl_manifest" "locust_master_svc" {
  yaml_body = <<YAML
apiVersion: v1
kind: Service
metadata:
  labels:
    role: locust-master
  name: locust-master
spec:
  type: ClusterIP
  ports:
  - port: 5557
    name: communication
  - port: 5558
    name: communication-plus-1
  - port: 8089
    targetPort: 8089
    name: web-ui
  selector:
    role: locust-master
    app: locust-master
YAML

  depends_on = [helm_release.cert_manager, kubectl_manifest.cluster_issuer, kubectl_manifest.elastic_vector, kubectl_manifest.kibana_vector, helm_release.ingress_nginx, kubectl_manifest.locust_master]
}

resource "kubectl_manifest" "locust_worker" {
  yaml_body = <<YAML
apiVersion: apps/v1
kind: Deployment
metadata:
  annotations:
    deployment.kubernetes.io/revision: "1"
  labels:
    role: locust-worker
    app: locust-worker
  name: locust-worker
spec:
  replicas: 2
  selector:
    matchLabels:
      role: locust-worker
      app: locust-worker
  strategy:
    rollingUpdate:
      maxSurge: 1
      maxUnavailable: 1
    type: RollingUpdate
  template:
    metadata:
      labels:
        role: locust-worker
        app: locust-worker
    spec:
      containers:
      - image: guisilveira/locust:elastic
        imagePullPolicy: Always
        name: worker
        args: ["--worker", "--master-host=locust-master"]
        env:
          - name: ES_USER
            value: "elastic"
          - name: ES_PASSWORD
            valueFrom:
              secretKeyRef:
                name: vector-es-elastic-user
                key: elastic
          - name: ES_URI
            value: "https://vector-es-http:9200"
        volumeMounts:
          - mountPath: /home/locust
            name: locust-scripts
          - name: es-http-ca
            mountPath: /tmp/ca.crt
            subPath: tls.crt
        resources: {}
        terminationMessagePath: /dev/termination-log
        terminationMessagePolicy: File
      dnsPolicy: ClusterFirst
      restartPolicy: Always
      schedulerName: default-scheduler
      securityContext: {}
      terminationGracePeriodSeconds: 30
      volumes:
      - name: locust-scripts
        configMap:
          name: scripts-cm
      - name: es-http-ca
        secret:
          secretName: vector-es-http-ca-internal
YAML

  depends_on = [helm_release.cert_manager, kubectl_manifest.cluster_issuer, kubectl_manifest.elastic_vector, kubectl_manifest.kibana_vector, helm_release.ingress_nginx, kubectl_manifest.locust_master_svc]
}

resource "kubectl_manifest" "ingress_locust" {
  yaml_body = <<YAML
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: locust
  annotations:
    cert-manager.io/cluster-issuer: "letsencrypt-vector"
spec:
  ingressClassName: nginx
  tls:
  - hosts:
      - ${var.dns_names[3]}
    secretName: letsencrypt-cert
  rules:
    - host: ${var.dns_names[3]}
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: locust-master
                port:
                  number: 8089
YAML

  depends_on = [helm_release.cert_manager, kubectl_manifest.cluster_issuer, kubectl_manifest.elastic_vector, kubectl_manifest.kibana_vector, helm_release.ingress_nginx, kubectl_manifest.locust_master_svc]
}