# Infraestrutura AWS do Comando

Terraform para provisionar a infraestrutura da aplicação Comando na AWS e executá-la em containers Docker nas instâncias EC2. O repositório da aplicação é o valor efetivo de `application_repository_url` no Terraform. Esse mesmo valor é usado pelo bootstrap e deve ser passado aos scripts de deploy por pull.

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
# Fase 1 do deploy por pull

O script consulta o HEAD de `main` no repositório indicado por `--repository-url` e verifica o último
run do workflow `ci.yml` para um push desse SHA. O GitHub informa a tentativa
atual de cada run em `run_attempt`. O script usa o maior `run_number` retornado,
inclusive quando a tentativa ainda está em andamento ou falhou, e confere o HEAD
novamente antes de emitir o SHA.

Execute a partir da raiz deste projeto com Bash, curl, Python 3 e awk:

```bash
bash scripts/check-deploy-ci.sh --repository-url "$APPLICATION_REPOSITORY_URL" --dry-run
bash tests/check-deploy-ci.sh
```

Os testes substituem o curl por respostas locais e funcionam sem acesso à rede.
Com ou sem `--dry-run`, esta fase se limita à consulta e à auditoria. O modo
`--dry-run` identifica a execução nos logs. A consulta ao GitHub é anônima.

| Código de saída | Resultado |
| --- | --- |
| 0 | HEAD elegível. O SHA é escrito em stdout. |
| 2 | Argumentos inválidos. |
| 10 | HEAD inelegível, CI ausente, pendente, reprovado, divergente ou HEAD alterado durante a consulta. |
| 20 | Validação indisponível por erro HTTP, timeout, resposta inválida ou listagem incompleta. |

Use 15 minutos como intervalo inicial entre consultas. O script faz uma única
rodada por chamada e escreve a auditoria em stderr. Em HTTP 403 ou 429,
registra `Retry-After` e `X-RateLimit-Reset` quando disponíveis. Um agendador
futuro deve respeitar o intervalo indicado pela API quando ele exceder 15 minutos.

## Fase 2 do deploy por pull

Defina `APPLICATION_REPOSITORY_URL` com o valor efetivo de
`application_repository_url` usado na implantação da EC2, incluindo eventuais
overrides. Por exemplo, com o mesmo workspace e argumentos de variáveis do
Terraform, avalie apenas `var.application_repository_url` no `terraform console`.
A URL deve ser HTTPS do GitHub, sem autenticação embutida. A consulta do CI, o
fetch e o `origin` do bootstrap devem apontar para o mesmo repositório. Uma
divergência com o `origin` bloqueia o modo `apply`.

```bash
bash scripts/pull-deploy.sh --repository-url "$APPLICATION_REPOSITORY_URL" --dry-run
bash tests/check-deploy-ci.sh
bash tests/pull-deploy.sh
```

O dry-run é o modo padrão. Ele consulta o GitHub e emite o SHA elegível. Os
testes usam respostas locais e simulam as operações de Git, Docker, EFS e flock.

### Ativação manual após autorização

1. Na EC2 escolhida, disponibilize os arquivos de `scripts/` juntos em um
   diretório fora do checkout, protegido contra escrita por usuários da aplicação.
   Em instâncias lançadas com a Fase 3, use o comando instalado abaixo.
   Use a conta autorizada a operar Docker e escrever em `/opt/comando`. Confirme
   Bash, curl, Python 3, Git, GNU timeout, flock, findmnt e Compose com suporte a
   `up --wait`. Confirme o EFS montado e a saúde dos quatro serviços e do alvo no ALB.
2. Execute o dry-run. Revise o SHA retornado, especialmente alterações de
   schema, compatibilidade com as versões ainda na frota, dados e filas.
   O script bloqueia mudanças no `compose.yaml` de produção e exige que os nomes
   de migrations do candidato coincidam com o histórico aplicado no RDS. Essa
   comparação cobre migrations pendentes, histórico ausente e migrations removidas.
   A revisão humana cobre mudanças sem migration nova, inclusive alterações no
   conteúdo de migrations existentes.
3. Coordene uma janela sem outros deploys, operações de schema ou inicializações
   que executem o instalador. Execute em uma EC2 por vez, aguarde o alvo ficar
   saudável no ALB e confirme a aplicação antes de avançar. A recriação dos
   serviços na porta existente pode interromper o tráfego dessa instância.

   ```bash
   bash scripts/pull-deploy.sh --repository-url "$APPLICATION_REPOSITORY_URL" --apply "$SHA_REVISADO"
   ```

4. Acompanhe a auditoria em stderr. O estado fica em
   `/opt/comando/pull-releases/state`. Se houver interrupção durante a troca, a
   próxima chamada explícita de `--apply` tenta restaurar a versão registrada e
   encerra a rodada antes de consultar o CI. Se o rollback falhar, o registro da
   troca fica em disco. Corrija a causa e repita o comando para tentar a recuperação.

A primeira aplicação lê o SHA do checkout do bootstrap, exige que os arquivos
rastreados estejam limpos, confere as referências e IDs das imagens em execução,
os quatro serviços e `/health`, e conserva tags locais de rollback. Se esse SHA
for o HEAD aprovado e revisado, registra a baseline e encerra sem build ou
recriação de contêineres. A associação entre SHA e imagens depende do histórico
do bootstrap, pois as imagens legadas ainda não trazem um rótulo de revisão.
Cada candidato tem seu checkout e imagens por SHA. O
build usa um arquivo de ambiente vazio. Depois do build, os links da release
apontam para o `.env` e o diretório de certificados do bootstrap. A ativação usa
o override AWS original e o projeto Compose `comando`. A troca e o rollback
validam a configuração efetiva com `docker compose config --quiet`, passando
o `.env`, o override e o `COMANDO_TAG` da release e conferindo os arquivos de
ambiente e certificados. O script exige a
montagem NFS e confere o vínculo do volume de anexos antes das trocas. Mantenha as
imagens e arquivos das releases disponíveis para recuperação. As saídas de
build e execução do Compose ficam suprimidas. A auditoria usa campos controlados
para registrar a etapa, a release e, em falhas de configuração ou ativação,
o código de saída. Falhas de saúde identificam o serviço ou o endpoint.

### Bloqueio entre instâncias

O `flock` serializa os comandos locais. Um contêiner temporário da release
ativa abre uma sessão PostgreSQL com os parâmetros TLS do bootstrap e tenta
`pg_try_advisory_lock(2026111701)`. A sessão permanece aberta da verificação
de schema até a confirmação da ativação ou a conclusão do rollback. A
recuperação após reinício tenta adquirir o mesmo lock antes de trocar
contêineres. Se o lock estiver ocupado, a operação é adiada.

O script confirma a sessão imediatamente antes de cada troca e antes de
registrar sucesso. Se a sessão cair durante um comando Docker, a perda pode
ser detectada somente no próximo ponto de verificação. Nesse caso a troca
fica pendente para recuperação sob um novo lock. Valide esse comportamento
com o RDS e o Docker reais na janela de teste.

## Fase 3 do deploy por pull

O Launch Template inclui os quatro arquivos de deploy no user data comprimido.
Após iniciar a aplicação, o bootstrap instala os arquivos em
`/usr/local/lib/comando-pull` e o comando `/usr/local/sbin/comando-pull`, que usa
a mesma URL configurada para o checkout inicial. Os arquivos instalados
pertencem ao root.

O timer systemd vem desativado por padrão. Defina
`pull_deploy_timer_enabled = true` em `terraform.tfvars` para habilitar o
dry-run periódico em novas instâncias. A consulta roda a cada 15 minutos,
com atraso aleatório de até 2 minutos para distribuir as chamadas da frota.
Após HTTP 403 ou 429, a unidade registra localmente o prazo indicado por
`Retry-After` ou `X-RateLimit-Reset` e suspende as consultas até esse prazo.
O journal registra o SHA elegível ou o motivo da inelegibilidade.

~~~bash
sudo systemctl start comando-pull.service
sudo journalctl -u comando-pull.service -n 50 --no-pager
systemctl list-timers comando-pull.timer
~~~

Para aplicar um SHA autorizado, siga a janela e as verificações da Fase 2,
uma instância por vez.

~~~bash
sudo /usr/local/sbin/comando-pull --apply "$SHA_REVISADO"
~~~

Uma nova versão do Launch Template é usada pelas próximas EC2. Para instalar
a Fase 3 em toda a frota existente, programe um instance refresh e acompanhe
a saúde dos alvos no ALB. Uma EC2 substituída inicia em
`application_commit_sha`. Se a intenção for que novas EC2 iniciem na versão
promovida manualmente, atualize esse SHA no Terraform.
