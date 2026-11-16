# Scripts dos challenge labs

Scripts para rodar direto no **Cloud Shell** do lab. Cada script pergunta os
parâmetros no início (região, zona e nomes dos recursos). Basta ENTER para
aceitar o valor padrão, mas confira sempre os nomes no painel do seu lab.

| Lab | Skill badge | Comando |
|-----|-------------|---------|
| GSP313 | Implement Load Balancing on Compute Engine | `bash <(curl -sL https://raw.githubusercontent.com/dcpc-cesar-school/google-cloud-foundations/main/cli/gsp313.sh)` |
| GSP315 | Set Up an App Dev Environment on Google Cloud | `bash <(curl -sL https://raw.githubusercontent.com/dcpc-cesar-school/google-cloud-foundations/main/cli/gsp315.sh)` |
| GSP342 | Implement Cloud Security Fundamentals on Google Cloud | `bash <(curl -sL https://raw.githubusercontent.com/dcpc-cesar-school/google-cloud-foundations/main/cli/gsp342.sh)` |
| GSP301 | Deploy a Compute Instance with a Remote Startup Script | `bash <(curl -sL https://raw.githubusercontent.com/dcpc-cesar-school/google-cloud-foundations/main/cli/gsp301.sh)` |
| GSP303 | Configure Secure RDP using a Windows Bastion Host | `bash <(curl -sL https://raw.githubusercontent.com/dcpc-cesar-school/google-cloud-foundations/main/cli/gsp303.sh)` |
| GSP304 | Build and Deploy a Docker Image to a Kubernetes Cluster | `bash <(curl -sL https://raw.githubusercontent.com/dcpc-cesar-school/google-cloud-foundations/main/cli/gsp304.sh)` |
| GSP305 | Scale Out and Update a Containerized Application on a Kubernetes Cluster | `bash <(curl -sL https://raw.githubusercontent.com/dcpc-cesar-school/google-cloud-foundations/main/cli/gsp305.sh)` |
| GSP306 | Migrate a MySQL Database to Google Cloud SQL | `bash <(curl -sL https://raw.githubusercontent.com/dcpc-cesar-school/google-cloud-foundations/main/cli/gsp306.sh)` |
| GSP101 | Deploy and Troubleshoot a Website | `bash <(curl -sL https://raw.githubusercontent.com/dcpc-cesar-school/google-cloud-foundations/main/cli/gsp101.sh)` |

## Dicas

- Se o script parecer desatualizado (o GitHub guarda o link `raw` em cache por ~5 min), troque `main` pelo código do último commit no link.

- Rode o script no Cloud Shell **do projeto do lab** (o script mostra o projeto antes de executar).
- Se ele for interrompido, pode rodar de novo: recursos que já existem são ignorados.
- O balanceador HTTP global leva de 3 a 7 minutos para responder. Espere antes de clicar em *Check my progress*.

## Observações por lab

- **GSP342** (Cloud Security Fundamentals): neste lab a conta do aluno **não é Owner**. O papel personalizado e a conta de serviço já vêm criados, e o aluno só pode vincular os papéis do enunciado (condição `allow_only_curriculum_roles`). O cluster é privado: `kubectl` só funciona de dentro do `orca-jumphost`. Validado em 16/11/2026: a tarefa 5 só passou depois de **apagar e recriar** o deployment `hello-server` e o serviço. O script já faz isso.
