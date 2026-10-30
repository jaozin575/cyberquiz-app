-- =====================================================================
--  CyberQuiz — script completo PostgreSQL
--  Base..........: MER Chen "versão corrigida" + banco de 50 perguntas
--  SGBD..........: PostgreSQL 13 ou superior
--  Autor.........: <preencher>
--
--  COMO USAR
--    1) Criar o banco (fora deste script, não roda dentro de transação):
--         createdb cyberquiz
--       ou, no pgAdmin: botões em Databases > Create > cyberquiz
--
--    2) Executar este arquivo inteiro:
--         psql -d cyberquiz -v ON_ERROR_STOP=1 -f cyberquiz_postgres.sql
--       ou, no pgAdmin: Query Tool > abrir o arquivo > F5
--
--  O script é idempotente: pode ser executado de novo no mesmo banco.
--  Ele APAGA as tabelas do CyberQuiz e recria do zero.
--
--  O QUE ESTE ARQUIVO CRIA
--    8 tabelas  : categoria, publicador, idioma, fonte, pergunta,
--                 alternativa, jogador, pontuacao
--    4 funções  : fn_checar_gabarito, fn_pontos_da_alternativa
--    2 gatilhos : gabarito (no COMMIT) e cálculo de pontos (antes do INSERT)
--    4 views    : vw_ranking_geral, vw_ranking_por_categoria,
--                 vw_placar_jogador, vw_perguntas_por_categoria
--    1 carga    : 50 perguntas x 4 alternativas (1 correta cada)
-- =====================================================================

BEGIN;

-- ---------------------------------------------------------------------
-- 0) Limpeza — permite rodar o script mais de uma vez no mesmo banco
-- ---------------------------------------------------------------------
DROP VIEW  IF EXISTS vw_ranking_geral;
DROP VIEW  IF EXISTS vw_ranking_por_categoria;
DROP VIEW  IF EXISTS vw_placar_jogador;
DROP VIEW  IF EXISTS vw_perguntas_por_categoria;
DROP TABLE IF EXISTS pontuacao   CASCADE;
DROP TABLE IF EXISTS alternativa CASCADE;
DROP TABLE IF EXISTS pergunta    CASCADE;
DROP TABLE IF EXISTS jogador     CASCADE;
DROP TABLE IF EXISTS fonte       CASCADE;
DROP TABLE IF EXISTS idioma      CASCADE;
DROP TABLE IF EXISTS publicador  CASCADE;
DROP TABLE IF EXISTS categoria   CASCADE;
DROP FUNCTION IF EXISTS fn_checar_gabarito(INT)    CASCADE;
DROP FUNCTION IF EXISTS fn_pontos_da_alternativa() CASCADE;
DROP FUNCTION IF EXISTS fn_trg_alternativa()       CASCADE;
DROP FUNCTION IF EXISTS fn_trg_pergunta()          CASCADE;

-- =====================================================================
--  1) ENTIDADES DE APOIO
-- =====================================================================

CREATE TABLE categoria (
    id_categoria INTEGER      GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    nome         VARCHAR(100) NOT NULL,
    CONSTRAINT uq_categoria_nome UNIQUE (nome)
);

CREATE TABLE publicador (
    id_publicador INTEGER      GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    nome          VARCHAR(150) NOT NULL,
    CONSTRAINT uq_publicador_nome UNIQUE (nome)
);

CREATE TABLE idioma (
    id_idioma INTEGER     GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    nome      VARCHAR(80) NOT NULL,
    codigo    VARCHAR(10) NOT NULL,
    CONSTRAINT uq_idioma_nome   UNIQUE (nome),
    CONSTRAINT uq_idioma_codigo UNIQUE (codigo)
);

CREATE TABLE fonte (
    id_fonte  INTEGER      GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    descricao VARCHAR(250) NOT NULL,
    url       TEXT,
    -- A mesma URL não é cadastrada duas vezes. NULL não conflita:
    -- material impresso pode não ter endereço.
    CONSTRAINT uq_fonte_url UNIQUE (url)
);

-- =====================================================================
--  2) PERGUNTA
--     `codigo` preserva o identificador original (fact-001...) e é o que
--     o aplicativo e a equipe usam para se referir à pergunta. `titulo` e
--     `explicacao` são obrigatórios: a explicação aparece depois da
--     resposta.
-- =====================================================================

CREATE TABLE pergunta (
    id_pergunta   INTEGER      GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    codigo        VARCHAR(20)  NOT NULL,
    titulo        VARCHAR(150) NOT NULL,
    enunciado     TEXT         NOT NULL,
    explicacao    TEXT         NOT NULL,
    id_categoria  INTEGER      NOT NULL,
    id_fonte      INTEGER      NOT NULL,
    id_publicador INTEGER      NOT NULL,
    id_idioma     INTEGER      NOT NULL,

    CONSTRAINT uq_pergunta_codigo UNIQUE (codigo),
    CONSTRAINT ck_pergunta_codigo CHECK (codigo ~ '^fact-[0-9]{3}$'),

    CONSTRAINT fk_pergunta_categoria
        FOREIGN KEY (id_categoria)  REFERENCES categoria  (id_categoria),
    CONSTRAINT fk_pergunta_fonte
        FOREIGN KEY (id_fonte)      REFERENCES fonte      (id_fonte),
    CONSTRAINT fk_pergunta_publicador
        FOREIGN KEY (id_publicador) REFERENCES publicador (id_publicador),
    CONSTRAINT fk_pergunta_idioma
        FOREIGN KEY (id_idioma)     REFERENCES idioma     (id_idioma)
);

-- =====================================================================
--  3) ALTERNATIVA
--     Quantidade livre (o mínimo de 4 é garantido por gatilho), rótulo
--     único dentro da pergunta e um único valor lógico verdadeiro.
-- =====================================================================

CREATE TABLE alternativa (
    id_alternativa INTEGER     GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    id_pergunta    INTEGER     NOT NULL,
    identificador  VARCHAR(20) NOT NULL,
    texto          TEXT        NOT NULL,
    correta        BOOLEAN     NOT NULL DEFAULT FALSE,

    CONSTRAINT fk_alternativa_pergunta
        FOREIGN KEY (id_pergunta) REFERENCES pergunta (id_pergunta)
        ON DELETE CASCADE,

    CONSTRAINT uq_alternativa_identificador
        UNIQUE (id_pergunta, identificador),

    -- Necessária para a FK composta em PONTUACAO: garante que a
    -- alternativa escolhida pertença à pergunta respondida.
    CONSTRAINT uq_alternativa_chave
        UNIQUE (id_alternativa, id_pergunta)
);

-- No máximo UMA alternativa correta por pergunta.
CREATE UNIQUE INDEX ux_alternativa_uma_correta
    ON alternativa (id_pergunta) WHERE correta;

-- =====================================================================
--  4) JOGADOR
-- =====================================================================

CREATE TABLE jogador (
    id_jogador INTEGER      GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    nome       VARCHAR(120) NOT NULL,
    email      VARCHAR(254) NOT NULL,
    senha_hash TEXT         NOT NULL,
    criado_em  TIMESTAMPTZ  NOT NULL DEFAULT NOW()
);

-- E-mail único sem diferenciar maiúsculas de minúsculas.
CREATE UNIQUE INDEX ux_jogador_email ON jogador (LOWER(email));

-- =====================================================================
--  5) PONTUACAO
--     Liga jogador, pergunta e a alternativa escolhida.
-- =====================================================================

CREATE TABLE pontuacao (
    id_pontuacao   INTEGER     GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    id_jogador     INTEGER     NOT NULL,
    id_pergunta    INTEGER     NOT NULL,
    id_alternativa INTEGER     NOT NULL,
    valor_pontos   INTEGER     NOT NULL DEFAULT 0,
    data_resposta  TIMESTAMPTZ NOT NULL DEFAULT NOW(),

    CONSTRAINT ck_pontuacao_valor CHECK (valor_pontos >= 0),

    CONSTRAINT fk_pontuacao_jogador
        FOREIGN KEY (id_jogador)  REFERENCES jogador  (id_jogador)  ON DELETE CASCADE,
    CONSTRAINT fk_pontuacao_pergunta
        FOREIGN KEY (id_pergunta) REFERENCES pergunta (id_pergunta) ON DELETE CASCADE,

    -- A alternativa escolhida precisa pertencer à pergunta respondida.
    CONSTRAINT fk_pontuacao_alternativa
        FOREIGN KEY (id_alternativa, id_pergunta)
        REFERENCES alternativa (id_alternativa, id_pergunta),

    -- Um jogador responde cada pergunta uma única vez.
    CONSTRAINT uq_pontuacao_jogador_pergunta
        UNIQUE (id_jogador, id_pergunta)
);

-- =====================================================================
--  6) REGRAS DE NEGÓCIO QUE NÃO CABEM EM UMA COLUNA
-- =====================================================================

-- 6.1) Toda pergunta tem no mínimo 4 alternativas e exatamente 1 correta.
--      Verificado no COMMIT para permitir inserir a pergunta e as suas
--      alternativas na mesma transação.
CREATE FUNCTION fn_checar_gabarito(p_id_pergunta INT) RETURNS VOID AS $$
DECLARE
    v_total    INT;
    v_corretas INT;
BEGIN
    -- pergunta já removida (DELETE em cascata): nada a validar
    IF NOT EXISTS (SELECT 1 FROM pergunta WHERE id_pergunta = p_id_pergunta) THEN
        RETURN;
    END IF;

    SELECT COUNT(*), COUNT(*) FILTER (WHERE correta)
      INTO v_total, v_corretas
      FROM alternativa
     WHERE id_pergunta = p_id_pergunta;

    IF v_total < 4 THEN
        RAISE EXCEPTION 'Pergunta % tem % alternativa(s); o minimo e 4.',
                        p_id_pergunta, v_total;
    END IF;

    IF v_corretas <> 1 THEN
        RAISE EXCEPTION 'Pergunta % tem % alternativa(s) correta(s); deve haver exatamente 1.',
                        p_id_pergunta, v_corretas;
    END IF;
END;
$$ LANGUAGE plpgsql;

CREATE FUNCTION fn_trg_alternativa() RETURNS TRIGGER AS $$
BEGIN
    IF TG_OP IN ('UPDATE', 'DELETE') THEN
        PERFORM fn_checar_gabarito(OLD.id_pergunta);
    END IF;
    IF TG_OP IN ('INSERT', 'UPDATE') THEN
        PERFORM fn_checar_gabarito(NEW.id_pergunta);
    END IF;
    RETURN NULL;
END;
$$ LANGUAGE plpgsql;

CREATE FUNCTION fn_trg_pergunta() RETURNS TRIGGER AS $$
BEGIN
    PERFORM fn_checar_gabarito(NEW.id_pergunta);
    RETURN NULL;
END;
$$ LANGUAGE plpgsql;

CREATE CONSTRAINT TRIGGER trg_alternativa_gabarito
    AFTER INSERT OR UPDATE OR DELETE ON alternativa
    DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW EXECUTE FUNCTION fn_trg_alternativa();

CREATE CONSTRAINT TRIGGER trg_pergunta_gabarito
    AFTER INSERT ON pergunta
    DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW EXECUTE FUNCTION fn_trg_pergunta();

-- 6.2) valor_pontos é calculado pelo banco: 10 se a alternativa escolhida
--      for a correta, 0 se não for. O aplicativo pode mandar o valor que
--      quiser — o banco sobrescreve. Para mudar a pontuação, altere o 10.
CREATE FUNCTION fn_pontos_da_alternativa() RETURNS TRIGGER AS $$
BEGIN
    SELECT CASE WHEN correta THEN 10 ELSE 0 END
      INTO NEW.valor_pontos
      FROM alternativa
     WHERE id_alternativa = NEW.id_alternativa;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_pontuacao_calcula
    BEFORE INSERT OR UPDATE OF id_alternativa ON pontuacao
    FOR EACH ROW EXECUTE FUNCTION fn_pontos_da_alternativa();

-- =====================================================================
--  7) ÍNDICES AUXILIARES
-- =====================================================================

CREATE INDEX idx_pergunta_categoria  ON pergunta (id_categoria);
CREATE INDEX idx_pergunta_fonte      ON pergunta (id_fonte);
CREATE INDEX idx_pergunta_publicador ON pergunta (id_publicador);
CREATE INDEX idx_pergunta_idioma     ON pergunta (id_idioma);
CREATE INDEX idx_pontuacao_jogador   ON pontuacao (id_jogador);
CREATE INDEX idx_pontuacao_pergunta  ON pontuacao (id_pergunta);

-- =====================================================================
--  8) VIEWS DE CONSULTA
-- =====================================================================

-- RA01 — categorias em ordem alfabética com a quantidade de perguntas.
CREATE VIEW vw_perguntas_por_categoria AS
SELECT c.id_categoria,
       c.nome AS categoria,
       COUNT(q.id_pergunta) AS quantidade_perguntas
  FROM categoria c
  LEFT JOIN pergunta q ON q.id_categoria = c.id_categoria
 GROUP BY c.id_categoria, c.nome;

-- Placar de um jogador — é o que a API /api/placar devolve.
CREATE VIEW vw_placar_jogador AS
SELECT j.id_jogador,
       j.nome,
       COALESCE(SUM(p.valor_pontos), 0)::INT             AS pontos,
       COUNT(p.id_pontuacao)::INT                        AS respondidas,
       (COUNT(*) FILTER (WHERE p.valor_pontos > 0))::INT AS acertos
  FROM jogador j
  LEFT JOIN pontuacao p ON p.id_jogador = j.id_jogador
 GROUP BY j.id_jogador, j.nome;

-- Ranking geral: soma de pontos por jogador. Ranking não é entidade.
CREATE VIEW vw_ranking_geral AS
SELECT RANK() OVER (ORDER BY COALESCE(SUM(p.valor_pontos), 0) DESC) AS posicao,
       j.id_jogador,
       j.nome,
       COALESCE(SUM(p.valor_pontos), 0)::INT             AS total_pontos,
       COUNT(p.id_pontuacao)::INT                        AS perguntas_respondidas,
       (COUNT(*) FILTER (WHERE p.valor_pontos > 0))::INT AS acertos
  FROM jogador j
  LEFT JOIN pontuacao p ON p.id_jogador = j.id_jogador
 GROUP BY j.id_jogador, j.nome;

-- Ranking por categoria: soma de pontos dentro de cada categoria.
CREATE VIEW vw_ranking_por_categoria AS
SELECT c.id_categoria,
       c.nome AS categoria,
       RANK() OVER (PARTITION BY c.id_categoria
                    ORDER BY SUM(p.valor_pontos) DESC) AS posicao,
       j.id_jogador,
       j.nome AS jogador,
       SUM(p.valor_pontos)::INT   AS total_pontos,
       COUNT(p.id_pontuacao)::INT AS perguntas_respondidas
  FROM pontuacao p
  JOIN jogador   j ON j.id_jogador   = p.id_jogador
  JOIN pergunta  q ON q.id_pergunta  = p.id_pergunta
  JOIN categoria c ON c.id_categoria = q.id_categoria
 GROUP BY c.id_categoria, c.nome, j.id_jogador, j.nome;

-- =====================================================================
--  9) DOMÍNIO FIXO
-- =====================================================================

INSERT INTO idioma (nome, codigo) VALUES
    ('Português', 'pt'),
    ('Inglês',    'en'),
    ('Espanhol',  'es');

INSERT INTO categoria (nome) VALUES
    ('Banco de Dados'),
    ('Desenvolvimento'),
    ('Inteligência Artificial'),
    ('Raciocínio');

INSERT INTO publicador (nome) VALUES
    ('Equipe CyberQuiz'),
    ('MDN Web Docs'),
    ('PostgreSQL Global Development Group');

INSERT INTO fonte (descricao, url) VALUES
    ('Banco de perguntas de conhecimentos de TI do CyberQuiz', NULL),
    ('MDN Web Docs', 'https://developer.mozilla.org/pt-BR/'),
    ('Documentação PostgreSQL', 'https://www.postgresql.org/docs/');

-- =====================================================================
-- 10) CARGA — 50 PERGUNTAS
--     codigo fact-001..fact-050. A fonte acompanha a categoria:
--       Raciocínio / Inteligência Artificial -> banco de perguntas da equipe
--       Desenvolvimento                      -> MDN Web Docs
--       Banco de Dados                       -> Documentação PostgreSQL
-- =====================================================================

INSERT INTO pergunta (codigo, titulo, enunciado, explicacao, id_categoria, id_fonte, id_publicador, id_idioma)
SELECT v.codigo, v.titulo, v.enunciado, v.explicacao,
       c.id_categoria, f.id_fonte, p.id_publicador, i.id_idioma
  FROM (VALUES
    (1,  'fact-001', 'Repetição com while',
        'Qual estrutura é usada para repetir um bloco de código enquanto uma condição for verdadeira?',
        'O while repete o bloco enquanto a condição continuar verdadeira; if, switch e return não repetem nada.',
        'Raciocínio', 'Banco de perguntas de conhecimentos de TI do CyberQuiz'),

    (2,  'fact-002', 'HTML e estrutura',
        'Qual linguagem é usada principalmente para estruturar o conteúdo de páginas web?',
        'HTML marca a estrutura do conteúdo; SQL consulta bancos e Bash é um shell de linha de comando.',
        'Desenvolvimento', 'MDN Web Docs'),

    (3,  'fact-003', 'Modelo de aprendizado',
        'Em inteligência artificial, o que é um modelo de aprendizado de máquina?',
        'É um sistema treinado a partir de dados para identificar padrões e generalizar para dados novos.',
        'Inteligência Artificial', 'Banco de perguntas de conhecimentos de TI do CyberQuiz'),

    (4,  'fact-004', 'SELECT',
        'Qual comando SQL consulta dados de uma tabela?',
        'SELECT lê dados; INSERT inclui, UPDATE altera e DELETE remove.',
        'Banco de Dados', 'Documentação PostgreSQL'),

    (5,  'fact-005', 'Operador lógico E',
        'Qual operador lógico representa a condição "E" em muitas linguagens de programação?',
        'O E lógico é escrito && em C e JavaScript; || é o OU, ! é a negação e % é o resto da divisão.',
        'Raciocínio', 'Banco de perguntas de conhecimentos de TI do CyberQuiz'),

    (6,  'fact-006', 'Link em HTML',
        'Qual estrutura HTML representa um link para outra página?',
        'O elemento <a> cria hiperligações; <p> é parágrafo, <img> é imagem e <table> é tabela.',
        'Desenvolvimento', 'MDN Web Docs'),

    (7,  'fact-007', 'Aplicação de IA',
        'Qual é uma aplicação comum de inteligência artificial?',
        'Reconhecer fala em assistentes virtuais é uma tarefa típica de IA; as outras opções são hardware.',
        'Inteligência Artificial', 'Banco de perguntas de conhecimentos de TI do CyberQuiz'),

    (8,  'fact-008', 'Chave primária',
        'Em um banco de dados relacional, para que serve uma chave primária?',
        'A chave primária identifica cada registro de forma única e não aceita repetição nem nulo.',
        'Banco de Dados', 'Documentação PostgreSQL'),

    (9,  'fact-009', 'Expressão aritmética',
        'Se x = 4, qual será o valor de x * 3 + 2?',
        'A multiplicação tem precedência: 4 * 3 = 12, e 12 + 2 = 14.',
        'Raciocínio', 'Banco de perguntas de conhecimentos de TI do CyberQuiz'),

    (10, 'fact-010', 'Linguagem de programação',
        'Qual destas opções é uma linguagem de programação?',
        'Python é linguagem de programação; HTTP é protocolo, CSS é linguagem de estilo e JPEG é formato de imagem.',
        'Desenvolvimento', 'MDN Web Docs'),

    (11, 'fact-011', 'Treinamento de modelo',
        'O que significa treinar um modelo de aprendizado de máquina?',
        'Treinar é fornecer dados para que o modelo ajuste seus parâmetros e aprenda padrões.',
        'Inteligência Artificial', 'Banco de perguntas de conhecimentos de TI do CyberQuiz'),

    (12, 'fact-012', 'INSERT',
        'Qual comando SQL adiciona novos registros a uma tabela?',
        'INSERT insere linhas novas; ALTER muda a estrutura, DROP apaga objetos e SELECT só lê.',
        'Banco de Dados', 'Documentação PostgreSQL'),

    (13, 'fact-013', 'Sequência geométrica',
        'Qual é o próximo número da sequência 2, 4, 8, 16, ...?',
        'Cada termo dobra o anterior, então 16 * 2 = 32.',
        'Raciocínio', 'Banco de perguntas de conhecimentos de TI do CyberQuiz'),

    (14, 'fact-014', 'Papel do CSS',
        'Para que serve o CSS em um site?',
        'O CSS define aparência e estilo dos elementos; armazenar dados é papel do banco.',
        'Desenvolvimento', 'MDN Web Docs'),

    (15, 'fact-015', 'Processamento de linguagem natural',
        'O que é processamento de linguagem natural (PLN)?',
        'PLN é a área da IA que trata a linguagem humana, como tradução, resumo e análise de sentimento.',
        'Inteligência Artificial', 'Banco de perguntas de conhecimentos de TI do CyberQuiz'),

    (16, 'fact-016', 'Cláusula WHERE',
        'Qual cláusula SQL filtra registros conforme uma condição?',
        'WHERE aplica a condição linha a linha; ORDER BY ordena, GROUP BY agrupa e CREATE cria objetos.',
        'Banco de Dados', 'Documentação PostgreSQL'),

    (17, 'fact-017', 'Condição em algoritmo',
        'Em um algoritmo, o que representa uma condição?',
        'Uma condição é uma expressão avaliada como verdadeira ou falsa e decide o caminho do algoritmo.',
        'Raciocínio', 'Banco de perguntas de conhecimentos de TI do CyberQuiz'),

    (18, 'fact-018', 'Controle de versão',
        'Qual ferramenta é usada para controlar versões do código-fonte?',
        'Git registra o histórico das alterações do código; Paint é editor de imagem e BIOS é firmware.',
        'Desenvolvimento', 'MDN Web Docs'),

    (19, 'fact-019', 'Dados de treinamento',
        'O que é um conjunto de dados de treinamento?',
        'É a massa de dados usada para ensinar o modelo a reconhecer padrões.',
        'Inteligência Artificial', 'Banco de perguntas de conhecimentos de TI do CyberQuiz'),

    (20, 'fact-020', 'Chave estrangeira',
        'Qual é a função de uma chave estrangeira?',
        'A chave estrangeira liga registros de tabelas diferentes e garante que a referência exista.',
        'Banco de Dados', 'Documentação PostgreSQL'),

    (21, 'fact-021', 'Operador de igualdade',
        'Qual operador costuma verificar se dois valores são iguais em linguagens como C e JavaScript?',
        '== compara valores; = atribui. Os operadores != e <= fazem outras comparações.',
        'Raciocínio', 'Banco de perguntas de conhecimentos de TI do CyberQuiz'),

    (22, 'fact-022', 'O que é API',
        'O que é uma API?',
        'API é a interface que permite a comunicação entre sistemas, expondo operações sem revelar a implementação.',
        'Desenvolvimento', 'MDN Web Docs'),

    (23, 'fact-023', 'Viés em IA',
        'Qual é um risco de um modelo de IA treinado com dados enviesados?',
        'Dados enviesados levam a resultados injustos ou distorcidos, mesmo com o modelo tecnicamente correto.',
        'Inteligência Artificial', 'Banco de perguntas de conhecimentos de TI do CyberQuiz'),

    (24, 'fact-024', 'UPDATE',
        'Qual comando SQL altera dados já existentes em uma tabela?',
        'UPDATE modifica linhas existentes; CREATE cria, SELECT lê e GRANT concede permissões.',
        'Banco de Dados', 'Documentação PostgreSQL'),

    (25, 'fact-025', 'Atribuição acumulada',
        'Se todas as variáveis começam em zero e executamos x = x + 5, qual é o valor final de x?',
        'Começando em 0, x = 0 + 5 resulta 5.',
        'Raciocínio', 'Banco de perguntas de conhecimentos de TI do CyberQuiz'),

    (26, 'fact-026', 'Testes de software',
        'Qual é a finalidade principal de testes de software?',
        'Testar serve para verificar se o programa se comporta conforme o esperado antes de chegar ao usuário.',
        'Desenvolvimento', 'MDN Web Docs'),

    (27, 'fact-027', 'Sistemas de recomendação',
        'Qual técnica é frequentemente usada para recomendar filmes com base nas preferências de usuários?',
        'Sistemas de recomendação usam o histórico e a semelhança entre usuários e itens.',
        'Inteligência Artificial', 'Banco de perguntas de conhecimentos de TI do CyberQuiz'),

    (28, 'fact-028', 'Normalização',
        'O que significa normalização em bancos de dados relacionais?',
        'Normalizar é organizar as tabelas para reduzir redundância e evitar anomalias de inserção, alteração e exclusão.',
        'Banco de Dados', 'Documentação PostgreSQL'),

    (29, 'fact-029', 'Tabela verdade: AND',
        'Qual será o resultado lógico de TRUE AND FALSE?',
        'O E lógico só é verdadeiro quando os dois lados são verdadeiros; aqui um lado é falso.',
        'Raciocínio', 'Banco de perguntas de conhecimentos de TI do CyberQuiz'),

    (30, 'fact-030', 'Compilador',
        'Qual é a função de um compilador?',
        'O compilador traduz o código-fonte para outra forma, como código de máquina ou bytecode.',
        'Desenvolvimento', 'MDN Web Docs'),

    (31, 'fact-031', 'Visão computacional',
        'Em visão computacional, qual tarefa identifica objetos em uma imagem?',
        'Detecção de objetos localiza e classifica elementos dentro da imagem.',
        'Inteligência Artificial', 'Banco de perguntas de conhecimentos de TI do CyberQuiz'),

    (32, 'fact-032', 'Tipo DATE',
        'Qual tipo de dado é adequado para armazenar uma data no PostgreSQL?',
        'DATE guarda apenas a data; BOOLEAN é lógico, BYTEA é binário e SERIAL é um inteiro sequencial.',
        'Banco de Dados', 'Documentação PostgreSQL'),

    (33, 'fact-033', 'Paridade por resto',
        'Um algoritmo verifica se um número é divisível por 2 usando o resto da divisão. Qual resto indica que ele é par?',
        'Um número é par quando a divisão por 2 tem resto 0; resto 1 indica ímpar.',
        'Raciocínio', 'Banco de perguntas de conhecimentos de TI do CyberQuiz'),

    (34, 'fact-034', 'Depuração',
        'O que é depuração (debugging)?',
        'Depurar é localizar e corrigir erros no comportamento de um programa.',
        'Desenvolvimento', 'MDN Web Docs'),

    (35, 'fact-035', 'Rede neural',
        'O que é uma rede neural artificial?',
        'É um modelo computacional inspirado de forma simplificada no funcionamento dos neurônios.',
        'Inteligência Artificial', 'Banco de perguntas de conhecimentos de TI do CyberQuiz'),

    (36, 'fact-036', 'ORDER BY',
        'Qual cláusula SQL ordena o resultado de uma consulta?',
        'ORDER BY define a ordenação; HAVING filtra grupos, VALUES alimenta o INSERT e REFERENCES declara FK.',
        'Banco de Dados', 'Documentação PostgreSQL'),

    (37, 'fact-037', 'Estrutura LIFO',
        'Qual estrutura de dados segue o princípio LIFO (último a entrar, primeiro a sair)?',
        'A pilha remove o último elemento inserido; a fila faz o contrário (FIFO).',
        'Raciocínio', 'Banco de perguntas de conhecimentos de TI do CyberQuiz'),

    (38, 'fact-038', 'Papel do JavaScript',
        'Qual é a função do JavaScript em muitos sites?',
        'JavaScript adiciona interatividade e comportamento; o estilo visual é papel do CSS.',
        'Desenvolvimento', 'MDN Web Docs'),

    (39, 'fact-039', 'Dados de validação',
        'Por que os dados de validação são usados durante o desenvolvimento de um modelo?',
        'Servem para avaliar e ajustar o modelo com dados que ele não viu no treinamento.',
        'Inteligência Artificial', 'Banco de perguntas de conhecimentos de TI do CyberQuiz'),

    (40, 'fact-040', 'Propriedades ACID',
        'O que uma transação de banco de dados busca garantir com propriedades ACID?',
        'ACID significa atomicidade, consistência, isolamento e durabilidade.',
        'Banco de Dados', 'Documentação PostgreSQL'),

    (41, 'fact-041', 'Busca linear',
        'Qual é a complexidade de tempo da busca linear, no pior caso, em uma lista com n elementos?',
        'No pior caso a busca linear percorre todos os n elementos, o que é O(n).',
        'Raciocínio', 'Banco de perguntas de conhecimentos de TI do CyberQuiz'),

    (42, 'fact-042', 'Interfaces web',
        'Qual tecnologia costuma ser usada para criar interfaces de páginas web?',
        'HTML, CSS e JavaScript formam a base das interfaces web.',
        'Desenvolvimento', 'MDN Web Docs'),

    (43, 'fact-043', 'Inferência',
        'O que é inferência em um modelo de aprendizado de máquina?',
        'Inferência é usar um modelo já treinado para produzir uma previsão ou resultado.',
        'Inteligência Artificial', 'Banco de perguntas de conhecimentos de TI do CyberQuiz'),

    (44, 'fact-044', 'Restrição UNIQUE',
        'Qual recurso do PostgreSQL pode impedir que o mesmo e-mail apareça duas vezes em uma coluna?',
        'A restrição UNIQUE (ou um índice único) impede valores repetidos na coluna.',
        'Banco de Dados', 'Documentação PostgreSQL'),

    (45, 'fact-045', 'Estrutura de decisão',
        'Qual estrutura é mais adequada para executar uma ação quando uma condição é verdadeira e outra quando é falsa?',
        'O if/else escolhe entre dois caminhos conforme a condição.',
        'Raciocínio', 'Banco de perguntas de conhecimentos de TI do CyberQuiz'),

    (46, 'fact-046', 'Design responsivo',
        'O que significa design responsivo em desenvolvimento web?',
        'O layout se adapta a diferentes tamanhos de tela, sem versões separadas do site.',
        'Desenvolvimento', 'MDN Web Docs'),

    (47, 'fact-047', 'Aprendizado supervisionado',
        'O que é aprendizado supervisionado?',
        'É o treinamento com exemplos que já trazem a resposta ou rótulo conhecido.',
        'Inteligência Artificial', 'Banco de perguntas de conhecimentos de TI do CyberQuiz'),

    (48, 'fact-048', 'DELETE',
        'Qual comando remove registros de uma tabela sem excluir a própria tabela?',
        'DELETE apaga linhas; DROP TABLE remove a tabela inteira e ALTER TABLE muda a estrutura.',
        'Banco de Dados', 'Documentação PostgreSQL'),

    (49, 'fact-049', 'Tabela verdade: OR',
        'Se uma condição A é verdadeira e uma condição B é falsa, qual é o resultado de A OR B?',
        'O OU lógico é verdadeiro quando pelo menos um dos lados é verdadeiro.',
        'Raciocínio', 'Banco de perguntas de conhecimentos de TI do CyberQuiz'),

    (50, 'fact-050', 'Proteção de senhas',
        'Qual prática ajuda a proteger senhas armazenadas por uma aplicação?',
        'Guardar apenas o hash com algoritmo adequado e salt dificulta a recuperação da senha original.',
        'Desenvolvimento', 'MDN Web Docs')
  ) AS v(ordem, codigo, titulo, enunciado, explicacao, categoria, fonte)
  JOIN categoria  c ON c.nome      = v.categoria
  JOIN fonte      f ON f.descricao = v.fonte
  JOIN publicador p ON p.nome      = CASE v.fonte
                                        WHEN 'MDN Web Docs'           THEN 'MDN Web Docs'
                                        WHEN 'Documentação PostgreSQL' THEN 'PostgreSQL Global Development Group'
                                        ELSE 'Equipe CyberQuiz'
                                     END
  JOIN idioma     i ON i.codigo    = 'pt'
 ORDER BY v.ordem;

-- =====================================================================
-- 11) CARGA — 200 ALTERNATIVAS (4 por pergunta, exatamente 1 correta)
-- =====================================================================

INSERT INTO alternativa (id_pergunta, identificador, texto, correta)
SELECT q.id_pergunta, a.identificador, a.texto, a.correta
  FROM (VALUES
    -- fact-001
    (1,  'fact-001', 'A', 'if', FALSE),
    (2,  'fact-001', 'B', 'while', TRUE),
    (3,  'fact-001', 'C', 'switch', FALSE),
    (4,  'fact-001', 'D', 'return', FALSE),
    -- fact-002
    (5,  'fact-002', 'A', 'HTML', TRUE),
    (6,  'fact-002', 'B', 'SQL', FALSE),
    (7,  'fact-002', 'C', 'Bash', FALSE),
    (8,  'fact-002', 'D', 'C', FALSE),
    -- fact-003
    (9,  'fact-003', 'A', 'Um componente físico do computador', FALSE),
    (10, 'fact-003', 'B', 'Um conjunto de regras para formatar textos', FALSE),
    (11, 'fact-003', 'C', 'Um sistema treinado para identificar padrões em dados', TRUE),
    (12, 'fact-003', 'D', 'Um tipo de cabo de rede', FALSE),
    -- fact-004
    (13, 'fact-004', 'A', 'UPDATE', FALSE),
    (14, 'fact-004', 'B', 'DELETE', FALSE),
    (15, 'fact-004', 'C', 'INSERT', FALSE),
    (16, 'fact-004', 'D', 'SELECT', TRUE),
    -- fact-005
    (17, 'fact-005', 'A', '||', FALSE),
    (18, 'fact-005', 'B', '&&', TRUE),
    (19, 'fact-005', 'C', '!', FALSE),
    (20, 'fact-005', 'D', '%', FALSE),
    -- fact-006
    (21, 'fact-006', 'A', '<p>', FALSE),
    (22, 'fact-006', 'B', '<img>', FALSE),
    (23, 'fact-006', 'C', '<a>', TRUE),
    (24, 'fact-006', 'D', '<table>', FALSE),
    -- fact-007
    (25, 'fact-007', 'A', 'Aumentar fisicamente a memória RAM', FALSE),
    (26, 'fact-007', 'B', 'Reconhecer fala em um assistente virtual', TRUE),
    (27, 'fact-007', 'C', 'Substituir o cabo de energia', FALSE),
    (28, 'fact-007', 'D', 'Formatar automaticamente qualquer disco', FALSE),
    -- fact-008
    (29, 'fact-008', 'A', 'Identificar unicamente cada registro', TRUE),
    (30, 'fact-008', 'B', 'Ordenar sempre os registros por nome', FALSE),
    (31, 'fact-008', 'C', 'Criptografar todas as colunas', FALSE),
    (32, 'fact-008', 'D', 'Permitir valores duplicados em todos os campos', FALSE),
    -- fact-009
    (33, 'fact-009', 'A', '10', FALSE),
    (34, 'fact-009', 'B', '12', FALSE),
    (35, 'fact-009', 'C', '14', TRUE),
    (36, 'fact-009', 'D', '18', FALSE),
    -- fact-010
    (37, 'fact-010', 'A', 'HTTP', FALSE),
    (38, 'fact-010', 'B', 'CSS', FALSE),
    (39, 'fact-010', 'C', 'JPEG', FALSE),
    (40, 'fact-010', 'D', 'Python', TRUE),
    -- fact-011
    (41, 'fact-011', 'A', 'Instalar uma placa de vídeo', FALSE),
    (42, 'fact-011', 'B', 'Fornecer dados para que o modelo aprenda padrões', TRUE),
    (43, 'fact-011', 'C', 'Aumentar o tamanho do monitor', FALSE),
    (44, 'fact-011', 'D', 'Criar uma senha para o usuário', FALSE),
    -- fact-012
    (45, 'fact-012', 'A', 'SELECT', FALSE),
    (46, 'fact-012', 'B', 'ALTER', FALSE),
    (47, 'fact-012', 'C', 'INSERT', TRUE),
    (48, 'fact-012', 'D', 'DROP', FALSE),
    -- fact-013
    (49, 'fact-013', 'A', '18', FALSE),
    (50, 'fact-013', 'B', '24', FALSE),
    (51, 'fact-013', 'C', '30', FALSE),
    (52, 'fact-013', 'D', '32', TRUE),
    -- fact-014
    (53, 'fact-014', 'A', 'Definir a aparência e o estilo dos elementos', TRUE),
    (54, 'fact-014', 'B', 'Armazenar dados em tabelas relacionais', FALSE),
    (55, 'fact-014', 'C', 'Gerenciar o processador', FALSE),
    (56, 'fact-014', 'D', 'Enviar e-mails automaticamente', FALSE),
    -- fact-015
    (57, 'fact-015', 'A', 'Uma técnica para resfriar computadores', FALSE),
    (58, 'fact-015', 'B', 'Um protocolo exclusivo de redes sem fio', FALSE),
    (59, 'fact-015', 'C', 'Uma área da IA que trabalha com linguagem humana', TRUE),
    (60, 'fact-015', 'D', 'Um tipo de memória permanente', FALSE),
    -- fact-016
    (61, 'fact-016', 'A', 'ORDER BY', FALSE),
    (62, 'fact-016', 'B', 'WHERE', TRUE),
    (63, 'fact-016', 'C', 'GROUP BY', FALSE),
    (64, 'fact-016', 'D', 'CREATE', FALSE),
    -- fact-017
    (65, 'fact-017', 'A', 'Uma imagem inserida no programa', FALSE),
    (66, 'fact-017', 'B', 'Uma conexão com a internet', FALSE),
    (67, 'fact-017', 'C', 'Um comentário sem efeito', FALSE),
    (68, 'fact-017', 'D', 'Uma expressão avaliada como verdadeira ou falsa', TRUE),
    -- fact-018
    (69, 'fact-018', 'A', 'Git', TRUE),
    (70, 'fact-018', 'B', 'Paint', FALSE),
    (71, 'fact-018', 'C', 'BIOS', FALSE),
    (72, 'fact-018', 'D', 'DHCP', FALSE),
    -- fact-019
    (73, 'fact-019', 'A', 'Uma lista de senhas de usuários', FALSE),
    (74, 'fact-019', 'B', 'Um arquivo que contém somente imagens de fundo', FALSE),
    (75, 'fact-019', 'C', 'Dados usados para ensinar um modelo a reconhecer padrões', TRUE),
    (76, 'fact-019', 'D', 'Um programa para limpar o teclado', FALSE),
    -- fact-020
    (77, 'fact-020', 'A', 'Aumentar a velocidade do processador', FALSE),
    (78, 'fact-020', 'B', 'Relacionar registros entre tabelas', TRUE),
    (79, 'fact-020', 'C', 'Impedir qualquer consulta SQL', FALSE),
    (80, 'fact-020', 'D', 'Guardar imagens obrigatoriamente', FALSE),
    -- fact-021
    (81, 'fact-021', 'A', '=', FALSE),
    (82, 'fact-021', 'B', '!=', FALSE),
    (83, 'fact-021', 'C', '<=', FALSE),
    (84, 'fact-021', 'D', '==', TRUE),
    -- fact-022
    (85, 'fact-022', 'A', 'Uma interface que permite a comunicação entre sistemas', TRUE),
    (86, 'fact-022', 'B', 'Um tipo de monitor', FALSE),
    (87, 'fact-022', 'C', 'Um sistema de refrigeração', FALSE),
    (88, 'fact-022', 'D', 'Uma linguagem exclusiva para planilhas', FALSE),
    -- fact-023
    (89, 'fact-023', 'A', 'Ele sempre ficará sem conexão', FALSE),
    (90, 'fact-023', 'B', 'Ele apagará necessariamente o sistema operacional', FALSE),
    (91, 'fact-023', 'C', 'Ele poderá produzir resultados injustos ou distorcidos', TRUE),
    (92, 'fact-023', 'D', 'Ele converterá todos os dados em áudio', FALSE),
    -- fact-024
    (93, 'fact-024', 'A', 'CREATE', FALSE),
    (94, 'fact-024', 'B', 'UPDATE', TRUE),
    (95, 'fact-024', 'C', 'SELECT', FALSE),
    (96, 'fact-024', 'D', 'GRANT', FALSE),
    -- fact-025
    (97, 'fact-025', 'A', '0', FALSE),
    (98, 'fact-025', 'B', '1', FALSE),
    (99, 'fact-025', 'C', '10', FALSE),
    (100,'fact-025', 'D', '5', TRUE),
    -- fact-026
    (101,'fact-026', 'A', 'Verificar se o programa se comporta conforme o esperado', TRUE),
    (102,'fact-026', 'B', 'Trocar automaticamente o sistema operacional', FALSE),
    (103,'fact-026', 'C', 'Aumentar o tamanho dos arquivos', FALSE),
    (104,'fact-026', 'D', 'Impedir a documentação do projeto', FALSE),
    -- fact-027
    (105,'fact-027', 'A', 'Desfragmentação de disco', FALSE),
    (106,'fact-027', 'B', 'Conversão de arquivos em PDF', FALSE),
    (107,'fact-027', 'C', 'Sistemas de recomendação', TRUE),
    (108,'fact-027', 'D', 'Protocolo ARP', FALSE),
    -- fact-028
    (109,'fact-028', 'A', 'Duplicar todos os dados em cada tabela', FALSE),
    (110,'fact-028', 'B', 'Organizar tabelas para reduzir redundâncias e anomalias', TRUE),
    (111,'fact-028', 'C', 'Apagar todas as chaves primárias', FALSE),
    (112,'fact-028', 'D', 'Converter tabelas em imagens', FALSE),
    -- fact-029
    (113,'fact-029', 'A', 'TRUE', FALSE),
    (114,'fact-029', 'B', 'NULL sempre', FALSE),
    (115,'fact-029', 'C', '1', FALSE),
    (116,'fact-029', 'D', 'FALSE', TRUE),
    -- fact-030
    (117,'fact-030', 'A', 'Traduzir código-fonte para outra forma executável ou intermediária', TRUE),
    (118,'fact-030', 'B', 'Criar cabos de rede', FALSE),
    (119,'fact-030', 'C', 'Armazenar arquivos em nuvem sem software', FALSE),
    (120,'fact-030', 'D', 'Proteger fisicamente o computador', FALSE),
    -- fact-031
    (121,'fact-031', 'A', 'Compactação de áudio', FALSE),
    (122,'fact-031', 'B', 'Roteamento de pacotes', FALSE),
    (123,'fact-031', 'C', 'Detecção de objetos', TRUE),
    (124,'fact-031', 'D', 'Indexação de tabelas SQL', FALSE),
    -- fact-032
    (125,'fact-032', 'A', 'BOOLEAN', FALSE),
    (126,'fact-032', 'B', 'DATE', TRUE),
    (127,'fact-032', 'C', 'BYTEA', FALSE),
    (128,'fact-032', 'D', 'SERIAL', FALSE),
    -- fact-033
    (129,'fact-033', 'A', '1', FALSE),
    (130,'fact-033', 'B', '-1', FALSE),
    (131,'fact-033', 'C', '2', FALSE),
    (132,'fact-033', 'D', '0', TRUE),
    -- fact-034
    (133,'fact-034', 'A', 'Localizar e corrigir erros em um programa', TRUE),
    (134,'fact-034', 'B', 'Criar uma conta de e-mail', FALSE),
    (135,'fact-034', 'C', 'Aumentar a resolução da tela', FALSE),
    (136,'fact-034', 'D', 'Excluir todas as variáveis de um projeto', FALSE),
    -- fact-035
    (137,'fact-035', 'A', 'Uma rede de cabos conectando roteadores', FALSE),
    (138,'fact-035', 'B', 'Uma tabela de banco de dados sem colunas', FALSE),
    (139,'fact-035', 'C', 'Um modelo computacional inspirado de forma simplificada em neurônios', TRUE),
    (140,'fact-035', 'D', 'Um tipo de licença de software', FALSE),
    -- fact-036
    (141,'fact-036', 'A', 'HAVING', FALSE),
    (142,'fact-036', 'B', 'ORDER BY', TRUE),
    (143,'fact-036', 'C', 'VALUES', FALSE),
    (144,'fact-036', 'D', 'REFERENCES', FALSE),
    -- fact-037
    (145,'fact-037', 'A', 'Fila', FALSE),
    (146,'fact-037', 'B', 'Árvore binária', FALSE),
    (147,'fact-037', 'C', 'Grafo', FALSE),
    (148,'fact-037', 'D', 'Pilha', TRUE),
    -- fact-038
    (149,'fact-038', 'A', 'Adicionar interatividade e comportamento às páginas', TRUE),
    (150,'fact-038', 'B', 'Definir exclusivamente o estilo visual', FALSE),
    (151,'fact-038', 'C', 'Substituir o protocolo DNS', FALSE),
    (152,'fact-038', 'D', 'Armazenar energia do computador', FALSE),
    -- fact-039
    (153,'fact-039', 'A', 'Para substituir permanentemente todos os dados de treinamento', FALSE),
    (154,'fact-039', 'B', 'Para aumentar a capacidade física do disco', FALSE),
    (155,'fact-039', 'C', 'Para avaliar e ajustar o modelo durante o desenvolvimento', TRUE),
    (156,'fact-039', 'D', 'Para gerar endereços IP automaticamente', FALSE),
    -- fact-040
    (157,'fact-040', 'A', 'Que toda tabela tenha exatamente quatro colunas', FALSE),
    (158,'fact-040', 'B', 'Atomicidade, consistência, isolamento e durabilidade', TRUE),
    (159,'fact-040', 'C', 'Que os dados sejam sempre públicos', FALSE),
    (160,'fact-040', 'D', 'Que não existam chaves estrangeiras', FALSE),
    -- fact-041
    (161,'fact-041', 'A', 'O(1)', FALSE),
    (162,'fact-041', 'B', 'O(log n)', FALSE),
    (163,'fact-041', 'C', 'O(n log n)', FALSE),
    (164,'fact-041', 'D', 'O(n)', TRUE),
    -- fact-042
    (165,'fact-042', 'A', 'HTML, CSS e JavaScript', TRUE),
    (166,'fact-042', 'B', 'SQL e PostgreSQL apenas', FALSE),
    (167,'fact-042', 'C', 'SMTP e IMAP apenas', FALSE),
    (168,'fact-042', 'D', 'BIOS e firmware apenas', FALSE),
    -- fact-043
    (169,'fact-043', 'A', 'O processo de montar fisicamente o computador', FALSE),
    (170,'fact-043', 'B', 'A etapa de limpar o teclado', FALSE),
    (171,'fact-043', 'C', 'Usar um modelo treinado para produzir uma previsão ou resultado', TRUE),
    (172,'fact-043', 'D', 'A instalação de uma impressora', FALSE),
    -- fact-044
    (173,'fact-044', 'A', 'ORDER BY', FALSE),
    (174,'fact-044', 'B', 'UNIQUE', TRUE),
    (175,'fact-044', 'C', 'LIMIT', FALSE),
    (176,'fact-044', 'D', 'OFFSET', FALSE),
    -- fact-045
    (177,'fact-045', 'A', 'CREATE TABLE', FALSE),
    (178,'fact-045', 'B', 'FOREIGN KEY', FALSE),
    (179,'fact-045', 'C', 'SELECT', FALSE),
    (180,'fact-045', 'D', 'if/else', TRUE),
    -- fact-046
    (181,'fact-046', 'A', 'A página adapta seu layout a diferentes tamanhos de tela', TRUE),
    (182,'fact-046', 'B', 'O site funciona somente em computadores antigos', FALSE),
    (183,'fact-046', 'C', 'O banco de dados responde a qualquer consulta sem índices', FALSE),
    (184,'fact-046', 'D', 'O código é convertido obrigatoriamente em áudio', FALSE),
    -- fact-047
    (185,'fact-047', 'A', 'Aprendizado sem uso de dados', FALSE),
    (186,'fact-047', 'B', 'Um método para conectar computadores em rede', FALSE),
    (187,'fact-047', 'C', 'Treinamento com exemplos que incluem respostas ou rótulos conhecidos', TRUE),
    (188,'fact-047', 'D', 'Um sistema de backup de arquivos', FALSE),
    -- fact-048
    (189,'fact-048', 'A', 'DROP TABLE', FALSE),
    (190,'fact-048', 'B', 'DELETE', TRUE),
    (191,'fact-048', 'C', 'CREATE TABLE', FALSE),
    (192,'fact-048', 'D', 'ALTER TABLE', FALSE),
    -- fact-049
    (193,'fact-049', 'A', 'FALSE', FALSE),
    (194,'fact-049', 'B', 'NULL obrigatoriamente', FALSE),
    (195,'fact-049', 'C', '0', FALSE),
    (196,'fact-049', 'D', 'TRUE', TRUE),
    -- fact-050
    (197,'fact-050', 'A', 'Armazenar hashes de senha com algoritmo apropriado e salt', TRUE),
    (198,'fact-050', 'B', 'Guardar senhas em texto puro', FALSE),
    (199,'fact-050', 'C', 'Usar a mesma senha para todos os usuários', FALSE),
    (200,'fact-050', 'D', 'Incluir a senha diretamente no código-fonte', FALSE)
  ) AS a(ordem, codigo, identificador, texto, correta)
  JOIN pergunta q ON q.codigo = a.codigo
 ORDER BY a.ordem;

-- =====================================================================
-- 12) JOGADOR DE DEMONSTRAÇÃO
--     O hash abaixo é FALSO: em produção a aplicação gera o hash (bcrypt)
--     e o banco nunca vê a senha em texto puro.
-- =====================================================================

INSERT INTO jogador (nome, email, senha_hash) VALUES
    ('Jogador de Teste', 'jogador.teste@example.com',
     'HASH_DE_EXEMPLO_NAO_UTILIZAR_EM_PRODUCAO');

-- Uma resposta certa (fact-001) e uma errada (fact-002), só para as views
-- de placar e ranking terem o que mostrar.
INSERT INTO pontuacao (id_jogador, id_pergunta, id_alternativa)
SELECT j.id_jogador, q.id_pergunta, a.id_alternativa
  FROM jogador j
  JOIN pergunta q    ON q.codigo        = 'fact-001'
  JOIN alternativa a ON a.id_pergunta   = q.id_pergunta
                    AND a.identificador = 'B'
 WHERE j.email = 'jogador.teste@example.com';

INSERT INTO pontuacao (id_jogador, id_pergunta, id_alternativa)
SELECT j.id_jogador, q.id_pergunta, a.id_alternativa
  FROM jogador j
  JOIN pergunta q    ON q.codigo        = 'fact-002'
  JOIN alternativa a ON a.id_pergunta   = q.id_pergunta
                    AND a.identificador = 'C'
 WHERE j.email = 'jogador.teste@example.com';

COMMIT;

-- =====================================================================
-- 13) CONFERÊNCIA
-- =====================================================================

-- Esperado: 4 categorias, 3 publicadores, 3 fontes, 3 idiomas,
-- 50 perguntas, 200 alternativas, 50 corretas (uma por pergunta).
SELECT (SELECT COUNT(*) FROM categoria)   AS categorias,
       (SELECT COUNT(*) FROM publicador)  AS publicadores,
       (SELECT COUNT(*) FROM fonte)       AS fontes,
       (SELECT COUNT(*) FROM idioma)      AS idiomas,
       (SELECT COUNT(*) FROM pergunta)    AS perguntas,
       (SELECT COUNT(*) FROM alternativa) AS alternativas,
       (SELECT COUNT(*) FROM alternativa WHERE correta) AS corretas;

-- Nenhuma linha deve aparecer aqui: toda pergunta precisa de 4
-- alternativas e exatamente 1 correta.
SELECT q.codigo, COUNT(a.id_alternativa) AS total,
       COUNT(a.id_alternativa) FILTER (WHERE a.correta) AS corretas
  FROM pergunta q
  LEFT JOIN alternativa a ON a.id_pergunta = q.id_pergunta
 GROUP BY q.codigo
HAVING COUNT(a.id_alternativa) <> 4
    OR COUNT(a.id_alternativa) FILTER (WHERE a.correta) <> 1
 ORDER BY q.codigo;

-- Placar e ranking de exemplo
SELECT * FROM vw_placar_jogador;
SELECT * FROM vw_ranking_geral;
