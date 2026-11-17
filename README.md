# Infraestrutura AWS do Comando

Terraform para provisionar a infraestrutura da aplicação [Comando](https://github.com/CarlosEduardo-N-O/comando) na AWS e executá-la em containers Docker nas instâncias EC2.

## Arquitetura provisionada

| Componente | Configuração |
| --- | --- |
| Região | `us-east-1` |
| Rede | VPC `10.0.0.0/16`; duas subnets públicas e duas privadas, distribuídas em `us-east-1a` e `us-east-1b` |
| Saída à internet | Internet Gateway; sem NAT Gateway |
| Entrada web | Application Load Balancer na porta 80, protegido por AWS WAF com Common Rule Set e Known Bad Inputs |
| Aplicação | Auto Scaling Group com Ubuntu 22.04 x86_64 e instâncias `t2.medium`; capacidade inicial 2 (mínimo 1, máximo 4), escala por CPU alvo de 60% |
| Containers | Frontend, backend PHP, worker e scheduler, executados com Docker Compose |
| Banco | Amazon RDS for PostgreSQL 17, classe `db.t3.micro`, 20 GiB gp3, privado, criptografado e com retenção de backup de 1 dia |
| Anexos | Amazon EFS criptografado, montado em todas as EC2 |
| Segredos | Credenciais gerenciadas do RDS, APP_KEY e senha inicial no AWS Secrets Manager |

O ALB encaminha para a porta 8080 dos servidores e verifica `/health`. As EC2 aceitam tráfego nessa porta somente do ALB; SSH fica desativado por padrão. As instâncias ficam nas subnets públicas para baixar o código e construir as imagens sem NAT. O acesso ao ALB é HTTP: configure domínio e certificado ACM antes de usar com dados reais.

Ao iniciar, cada EC2 instala Docker, baixa o commit configurado, constrói as imagens, monta o EFS e inicia os containers. O primeiro bootstrap pode levar vários minutos após o Terraform terminar.

## Pré-requisitos

- Conta AWS com permissões para VPC, EC2, Auto Scaling, ELBv2, WAFv2, RDS, EFS e Secrets Manager.
- AWS CLI v2 com credenciais temporárias válidas.
- Terraform 1.11.0 ou superior.
- Provedores Terraform AWS `~> 5.0` e Random `~> 3.6`, baixados por `terraform init`.
- Acesso à internet para o Terraform baixar provedores e para as EC2 baixarem o repositório, pacotes e imagens Docker.
- No AWS Academy, o perfil de instância preexistente `LabInstanceProfile`, com permissão de leitura dos segredos. Esse projeto o reutiliza; não cria IAM roles nem instance profiles.

Os limites e permissões do AWS Academy variam por laboratório. A sessão do laboratório precisa estar ativa e as credenciais temporárias não podem estar expiradas. Em outra conta AWS, configure `ec2_instance_profile_name` com um instance profile existente que permita às EC2 chamar `secretsmanager:GetSecretValue` para os segredos usados pela aplicação.

## 1. Configurar as credenciais AWS

Inicie o laboratório no AWS Academy e copie as credenciais temporárias da seção de acesso à AWS CLI. No Windows, armazene-as no arquivo de credenciais padrão da AWS CLI, fora deste repositório:

```powershell
$awsDirectory = Join-Path $env:USERPROFILE ".aws"
New-Item -ItemType Directory -Force -Path $awsDirectory | Out-Null
notepad (Join-Path $awsDirectory "credentials")
```

Use o formato abaixo e substitua os valores pelos fornecidos pelo laboratório:

```ini
[default]
aws_access_key_id = VALOR_FORNECIDO_PELO_LABORATORIO
aws_secret_access_key = VALOR_FORNECIDO_PELO_LABORATORIO
aws_session_token = VALOR_FORNECIDO_PELO_LABORATORIO
```

Não coloque essas credenciais em `terraform.tfvars`, no código Terraform ou no Git. Confirme a identidade e a validade das credenciais:

```powershell
aws sts get-caller-identity
```

O provedor AWS usa a cadeia padrão de credenciais da AWS CLI e a região definida em `terraform.tfvars`.

## 2. Revisar a configuração

Abra um terminal na raiz do repositório, onde está o arquivo `main.tf`. Crie seu arquivo local de configuração a partir do exemplo:

~~~powershell
Copy-Item terraform.tfvars.example terraform.tfvars
~~~

Edite `terraform.tfvars` antes de criar recursos. Esse arquivo é ignorado pelo Git para evitar publicar configurações locais ou segredos. O exemplo versionado contém:

- `ec2_instance_profile_name`: `LabInstanceProfile` no AWS Academy.
- `application_repository_url` e `application_commit_sha`: repositório e commit imutável da aplicação.
- `initial_admin_name` e `initial_admin_email`: nome e e-mail do administrador inicial.
- Capacidade do ASG, tamanho das instâncias e classe do banco.

O arquivo não contém senhas. Se alterar a região, revise também as zonas de disponibilidade configuradas.

## 3. Formatar e validar

Execute estes comandos na raiz do repositório:

```powershell
terraform fmt -recursive
terraform init
terraform validate
```

`terraform init` baixa as versões dos provedores declaradas no projeto e usa o arquivo `.terraform.lock.hcl`. Mantenha esse arquivo versionado para que outros colaboradores usem as mesmas versões.

## 4. Revisar o plano e provisionar

Gere um plano salvo e revise as alterações antes de aplicá-las:

```powershell
terraform plan -out=tfplan
terraform show tfplan
```

Se o plano estiver correto, aplique exatamente o plano revisado:

```powershell
terraform apply tfplan
```

O provisionamento cria recursos que podem gerar cobranças. O plano também pode conter dados sensíveis; não envie nem versione `tfplan`. O `.gitignore` deste repositório exclui planos, estado local e a pasta `.terraform`.

## 5. Acompanhar e acessar a aplicação

O Terraform pode terminar antes do bootstrap Docker das EC2. Aguarde alguns minutos e verifique a URL:

```powershell
$applicationUrl = terraform output -raw load_balancer_url
Invoke-RestMethod "$applicationUrl/health"
```

Uma resposta saudável inclui `"status":"ok"` e `"banco":"ok"`. A página principal fica na URL mostrada por:

```powershell
terraform output -raw load_balancer_url
```

### Senha do administrador inicial

O projeto gera uma senha aleatória e a guarda no Secrets Manager. Consulte o segredo após o provisionamento:

```powershell
$secretArn = terraform output -raw initial_admin_secret_arn
aws secretsmanager get-secret-value --secret-id $secretArn --query SecretString --output text
```

O resultado JSON contém `name`, `email` e `password`. A configuração inicial usa o e-mail `admin@comando.local`; troque a senha após o primeiro acesso.

## Atualizar a aplicação

Para selecionar outra versão, altere `application_commit_sha` em `terraform.tfvars`, gere e revise um novo plano e aplique-o. A alteração atualiza o launch template do ASG; instâncias que já estão rodando não são substituídas automaticamente. Faça um instance refresh do Auto Scaling Group para atualizar os servidores existentes e acompanhe a saúde dos alvos no ALB.

## Remover a infraestrutura

Antes de remover os recursos, faça backup do banco e dos anexos. O RDS está configurado sem snapshot final automático e os dados do EFS também serão removidos quando o sistema de arquivos for destruído.

```powershell
terraform plan -destroy -out=destroy.tfplan
terraform show destroy.tfplan
terraform apply destroy.tfplan
```

Revise o plano de destruição cuidadosamente: `terraform destroy` remove os recursos controlados por este estado.

## Estado e segurança

O estado local do Terraform pode conter dados sensíveis, incluindo valores usados para criar os segredos. Não versione `terraform.tfstate`, arquivos de backup do estado ou planos. Restrinja o acesso ao computador e, para trabalho em equipe, configure um backend remoto criptografado com controle de acesso e bloqueio de estado.

Este projeto não configura HTTPS, domínio, backup externo dos anexos ou proteção contra remoção do banco. Planeje esses itens antes de usar a aplicação em produção.
