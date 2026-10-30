# CyberQuiz Web (HTML, CSS, JavaScript + Node.js + PostgreSQL)

## Importante
O navegador não deve conectar diretamente ao PostgreSQL. O `server.js` é a API intermediária, que mantém as credenciais do banco no arquivo `.env`.

## Pré-requisitos
- Node.js LTS instalado
- PostgreSQL e pgAdmin
- As tabelas do CyberQuiz já criadas e as 50 perguntas inseridas

## Passo a passo (Windows)
1. Extraia o ZIP em uma pasta.
2. Abra a pasta no VS Code (recomendado) ou abra um terminal nessa pasta.
3. Copie `.env.example` para um arquivo chamado `.env`.
4. Edite `.env` com os dados da conexão PostgreSQL. `DB_NAME` deve ser o nome exato do banco que contém as tabelas. Coloque a senha real do usuário PostgreSQL em `DB_PASSWORD`. Troque `JWT_SECRET` por uma chave longa.
5. Abra o terminal nessa pasta e execute: `npm install`
6. Execute: `npm start`
7. Abra `http://localhost:3000` no navegador.
8. Crie uma conta, selecione uma categoria e comece a responder.

## Banco esperado
As tabelas devem ter estes nomes e colunas:
- categoria(id_categoria, nome)
- jogador(id_jogador, nome, email, senha_hash)
- pergunta(id_pergunta, enunciado, id_categoria, id_fonte, id_publicador, id_idioma)
- alternativa(id_alternativa, id_pergunta, identificador, texto, correta)
- pontuacao(id_pontuacao, valor_pontos, data_resposta, id_jogador, id_pergunta, id_alternativa)

O código também espera as chaves estrangeiras e a restrição `UNIQUE (id_jogador, id_pergunta)` criadas no SQL anterior.

## Como funciona
- Cadastro/login usa bcrypt para armazenar senhas com hash e JWT para autenticar chamadas.
- `GET /api/categorias` lista categorias.
- `GET /api/pergunta` ou `GET /api/pergunta?categoria=ID` traz uma pergunta ainda não respondida pelo jogador e suas alternativas, sem o gabarito.
- `POST /api/responder` verifica a alternativa no servidor e grava 10 pontos para acerto ou 0 para erro.
- `GET /api/placar` retorna o total de pontos, respostas e acertos do jogador.

## Solução de problemas
- Erro de conexão: confira serviço do PostgreSQL, DB_HOST, DB_PORT, DB_NAME, DB_USER e DB_PASSWORD no `.env`.
- Erro de tabela/coluna inexistente: confira se o SQL do banco foi executado no mesmo banco indicado por `DB_NAME`.
- Nenhuma pergunta: confira se existem perguntas e quatro alternativas por pergunta.
- E-mail já cadastrado: entre na conta existente ou use outro e-mail.

Este projeto é uma base didática para desenvolvimento local. Antes de publicar na internet, configure HTTPS, proteção contra tentativas de login, gerenciamento seguro de segredos e armazenamento de sessão/token apropriado.
