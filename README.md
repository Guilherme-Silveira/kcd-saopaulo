# KCD SÃO PAULO

- [KCD SÃO PAULO](#kcd-são-paulo)
  - [Terraform](#terraform)
    - [Pré Requisitos](#pré-requisitos)
    - [Arquitetura](#arquitetura)
    - [Step-by-Step](#step-by-step)
      - [Configurar credenciais](#configurar-credenciais)
      - [Criar o arquivo tfvars](#criar-o-arquivo-tfvars)
      - [Executar o Terraform init, plan e apply](#executar-o-terraform-init-plan-e-apply)
      - [Acesso ao cluster](#acesso-ao-cluster)
      - [Acesso aos serviços](#acesso-aos-serviços)
      - [Senha Elasticsearch/Kibana](#senha-elasticsearchkibana)
  - [Local](#local)
    - [Pré Requisitos](#pré-requisitos-1)
    - [Arquitetura](#arquitetura-1)
    - [Step-by-Step](#step-by-step-1)
      - [Criar o ambiente](#criar-o-ambiente)
      - [Acesso ao cluster](#acesso-ao-cluster-1)
      - [Acesso aos serviços](#acesso-aos-serviços-1)
      - [Senha Elasticsearch/Kibana](#senha-elasticsearchkibana-1)
  - [Arquitetura RAG demo](#arquitetura-rag-demo)
## Terraform

### Pré Requisitos

- [terraform CLI](https://developer.hashicorp.com/terraform/install)
- [gcloud CLI](https://cloud.google.com/sdk/docs/install)
- [kubectl](https://kubernetes.io/docs/tasks/tools/#kubectl)
- [Helm](https://helm.sh/docs/intro/install/)

### Arquitetura

O deploy do projeto usando Terraform cria um cluster Kubernetes no Google Cloud Platform, com NodeSets dedicados para o uso de GPU, instalação dos Drivers da NVIDIA para a utilização das GPUs e a configuração e deploy dos seguintes componentes:

- ECK (Elastic Cloud on Kubernetes) com Nodes dedicados para Machine Learning
- Jupyter Lab (Notebooks responsáveis pelo upload dos modelos de Machine Learning para dentro do ECK)
- Locust (Teste de Carga)
- Streamlit Application (Frontend que contém a lógica de implementação da arquitetura RAG)
- NGINX Ingress Controler para gerenciamento de acessos externos aos serviços do cluster Kubernetes
- Cert Manager para criação e gerenciamento automático de certificados SSL utilizando o Let's Encrypt como Autoridade Certificadora

### Step-by-Step

#### Configurar credenciais

Executar em seu terminal o seguinte comando:

```sh
gcloud auth application-default login
```

#### Criar o arquivo tfvars
Criar o arquivo `<any_name>.tfvars` (e.g., `mysetup.tfvars`) para definir as variáveis do seu ambiente. As variáveis estão descritas no arquivo `variables.tf`. Exemplo de um arquivo `.tfvars`:

```
email        = "myemail@mydomain.com"
openai_api   = "base64-encoded-openai-apikey"
project_name = "my-gcp-project"
region       = "my-gcp-region"
cluster_name = "my-k8s-cluster-name"
```

**NOTA**: A ApiKey da OpenAI **precisa** estar encoded em base64.

#### Executar o Terraform init, plan e apply

Para instalar e configurar todos os providers, executar o seguinte comando na sua máquina:

```sh
terraform init
```

Após isso, executar o comando:

```sh
terraform plan -var-file='mysetup.tfvars'
```

**NOTA**: Nesse caso, `mysetup.tfvars` é um exemplo de nome de arquivo criado no step anterior. Caso o seu arquivo `.tfvars` tenha um nome diferente, substitua `mysetup.tfvars` pelo nome do seu arquivo.

Caso o comando acima execute com sucesso, basta executar o `apply`:

```sh
terraform apply -var-file='mysetup.tfvars' -auto-approve
```

#### Acesso ao cluster

Após a execução do `terraform apply`, todos os serviços descritos na arquitetura estarão no ar. Para acessar o cluster Kubernetes criado, executar o seguinte comando:

```sh
gcloud container clusters get-credentials <KUBERNETES-NAME> --region <YOUR-REGION> --project <YOUR-PROJECT-NAME>
```

**NOTA**: Substituir os conteúdos entre `<` e `>` pelos valores que se adequem ao seu ambiente.

#### Acesso aos serviços

Há dois métodos:

- Port Forwarder: Utilizar o Port Forwarder do Kubernetes para acessar cada um dos serviços (não recomendado nesse cenário)
- Ingress: Será criado um Ingress para cada um dos serviços (Streamlit App, Locust, Elasticsearch, Kibana e Jupyter), porém apenas um External IP para o NGINX Ingress Controler. Para pegar o valor desse external IP, execute o comando: `kubectl get services -n ingress-nginx`. Uma vez coletado esse IP, no seu domínio (e.g., Route53, Google Domains, Cloudflare), crie registros do tipo A com os seus DNSs (exemplos descritos no arquivo `variables.tf`) apontando para o External IP do NGINX Ingress Controller coletado no passo anterior.
  - Poderia ser utilizada a ferramenta do `external_dns` para criação automática desses registros, porém nessa demo, eu estava utilizando o `Google Domains`, que não suportava a funcionalidade do `external_dns`.

#### Senha Elasticsearch/Kibana

Para acessar o Kibana, será necessário se autenticar com usuário e senha. O superuser da Stack é o usuário `elastic`. Para obter a senha desse usuário, execute o seguinte comando:

```sh
kubectl get secret vector-es-elastic-user -o=jsonpath='{.data.elastic}' | base64 --decode; echo
```

---
## Local

### Pré Requisitos

- [Docker](https://docs.docker.com/get-docker/)
- [k3d](https://k3d.io/v5.6.0/#releases)
- [Helm](https://helm.sh/docs/intro/install/)

### Arquitetura

A arquitetura dos componentes a serem instalados é a mesma do Deploy feito com o Terraform, porém, localmente o Let's Encrypt não pode ser utilizado e não teremos um domínio válido para acessar os serviços do cluster.

Para contornar esse cenário, como domínio, utilizaremos o `/etc/hosts` de sua máquina para definir os DNSs, apontando para localhost (127.0.0.1). Exemplo:

`cat /etc/hosts`
```
127.0.0.1 elasticsearch.silveira.com
127.0.0.1 kibana.silveira.com
127.0.0.1 jupyter.silveira.com
127.0.0.1 app.silveira.com
127.0.0.1 locust.silveira.com
```

**NOTA**: Modifique os DNSs listados acima para quaisquer DNSs que você deseje. Porém, uma vez mudado os DNSs, acesse os arquivos `local-k3d/certificate.yaml` e `local-k3d/ingress.yaml` e mude os valores de DNS para os novos DNSs deinifidos por você.

### Step-by-Step

#### Criar o ambiente
Para criar o ambiente local completo, execute o seguinte comando:

```sh
bash local-k3d/create-env.sh <OPENAI_APIKEY>
```

**NOTA**: Substitua `<OPENAI_APIKEY>` pelo valor da APIKey extraída do portal da OpenAI, porém, diferente do deploy feito com o Terraform, não use a APIKey encoded em base64. Use-a em Plaintext, ou seja, do jeito que foi extraída. Exemplo:

```sh
bash local-k3d/create-env.sh sk-12345678abcde
```

#### Acesso ao cluster
Após a execução do script, o `k3d` irá configurar automaticamente o contexto do `kubectl` para o cluster recém criado. O nome do contexto será `k3d-kds-default`.

#### Acesso aos serviços

Há dois métodos:

- Port Forwarder: Utilizar o Port Forwarder do Kubernetes para acessar cada um dos serviços
- Ingress: Será criado um Ingress para cada um dos serviços (Streamlit App, Locust, Elasticsearch, Kibana e Jupyter). Os DNSs para acessar os serviços são os DNSs que foram definidos no arquivo `/etc/hosts` de sua máquina no step de arquitetura do deploy local.

#### Senha Elasticsearch/Kibana

Para acessar o Kibana, será necessário se autenticar com usuário e senha. O superuser da Stack é o usuário `elastic`. Para obter a senha desse usuário, execute o seguinte comando:

```sh
kubectl get secret vector-es-elastic-user -o=jsonpath='{.data.elastic}' | base64 --decode; echo
```

## Arquitetura RAG demo

Para criar o Crawler, ingerir os dados nos índices, fazer upload do modelo para o Elasticsearch e utilizar a aplicação Web do Streamlit, siga os passos descritos aqui: [https://www.elastic.co/search-labs/blog/articles/chatgpt-elasticsearch-openai-meets-private-data#eland](https://www.elastic.co/search-labs/blog/articles/chatgpt-elasticsearch-openai-meets-private-data#eland), a partir do tópico `eland`.# kcd-saopaulo
