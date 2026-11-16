# Scripts dos challenge labs

Scripts para rodar direto no **Cloud Shell** do lab. Cada script pergunta os
parâmetros no início (região, zona e nomes dos recursos). Basta ENTER para
aceitar o valor padrão, mas confira sempre os nomes no painel do seu lab.

| Lab | Skill badge | Comando |
|-----|-------------|---------|
| GSP313 | Implement Load Balancing on Compute Engine | `bash <(curl -sL https://raw.githubusercontent.com/dcpc-cesar-school/google-cloud-foundations/main/cli/gsp313.sh)` |

## Dicas

- Rode o script no Cloud Shell **do projeto do lab** (o script mostra o projeto antes de executar).
- Se ele for interrompido, pode rodar de novo: recursos que já existem são ignorados.
- O balanceador HTTP global leva de 3 a 7 minutos para responder. Espere antes de clicar em *Check my progress*.
