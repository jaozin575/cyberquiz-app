require("dotenv").config();

const express = require("express");
const path = require("path");
const bcrypt = require("bcryptjs");
const jwt = require("jsonwebtoken");
const { Pool } = require("pg");

const app = express();
const PORT = process.env.PORT || 3000;
const JWT_SECRET = process.env.JWT_SECRET;

if (!JWT_SECRET) {
  console.error("ERRO: defina JWT_SECRET no arquivo .env");
  process.exit(1);
}

// Duas formas de conexao:
//  - DATABASE_URL  -> banco na nuvem (Supabase, Render, Neon...), com SSL
//  - DB_HOST/PORT/... -> PostgreSQL local, usado no desenvolvimento
// Se DATABASE_URL existir, ela ganha.
const pool = process.env.DATABASE_URL
  ? new Pool({
      connectionString: process.env.DATABASE_URL,
      ssl: { rejectUnauthorized: false },
      max: 3
    })
  : new Pool({
      host: process.env.DB_HOST || "localhost",
      port: Number(process.env.DB_PORT || 5432),
      database: process.env.DB_NAME,
      user: process.env.DB_USER,
      password: process.env.DB_PASSWORD
    });

app.use(express.json());
app.use(express.static(path.join(__dirname, "public")));

function criarToken(jogador) {
  return jwt.sign(
    { id_jogador: jogador.id_jogador, nome: jogador.nome },
    JWT_SECRET,
    { expiresIn: "8h" }
  );
}

function autenticar(req, res, next) {
  const cabecalho = req.headers.authorization || "";
  const token = cabecalho.startsWith("Bearer ") ? cabecalho.slice(7) : "";

  if (!token) {
    return res.status(401).json({ erro: "Entre na sua conta para continuar." });
  }

  try {
    req.jogador = jwt.verify(token, JWT_SECRET);
    next();
  } catch {
    return res.status(401).json({ erro: "Sessão inválida ou expirada. Entre novamente." });
  }
}

// Cadastro do jogador. A senha é armazenada como hash, nunca em texto puro.
app.post("/api/cadastro", async (req, res) => {
  const { nome, email, senha } = req.body;

  if (!nome || !email || !senha || senha.length < 6) {
    return res.status(400).json({ erro: "Informe nome, e-mail e senha com pelo menos 6 caracteres." });
  }

  try {
    const senhaHash = await bcrypt.hash(senha, 10);
    const resultado = await pool.query(
      `INSERT INTO jogador (nome, email, senha_hash)
       VALUES ($1, $2, $3)
       RETURNING id_jogador, nome, email`,
      [nome.trim(), email.trim().toLowerCase(), senhaHash]
    );

    const jogador = resultado.rows[0];
    res.status(201).json({
      token: criarToken(jogador),
      jogador: { id_jogador: jogador.id_jogador, nome: jogador.nome, email: jogador.email }
    });
  } catch (erro) {
    if (erro.code === "23505") {
      return res.status(409).json({ erro: "Este e-mail já está cadastrado." });
    }
    console.error(erro);
    res.status(500).json({ erro: "Não foi possível cadastrar. Confira a conexão com o banco." });
  }
});

// Login
app.post("/api/login", async (req, res) => {
  const { email, senha } = req.body;

  if (!email || !senha) {
    return res.status(400).json({ erro: "Informe e-mail e senha." });
  }

  try {
    const resultado = await pool.query(
      `SELECT id_jogador, nome, email, senha_hash
       FROM jogador WHERE email = $1`,
      [email.trim().toLowerCase()]
    );

    if (!resultado.rowCount || !(await bcrypt.compare(senha, resultado.rows[0].senha_hash))) {
      return res.status(401).json({ erro: "E-mail ou senha incorretos." });
    }

    const jogador = resultado.rows[0];
    res.json({
      token: criarToken(jogador),
      jogador: { id_jogador: jogador.id_jogador, nome: jogador.nome, email: jogador.email }
    });
  } catch (erro) {
    console.error(erro);
    res.status(500).json({ erro: "Não foi possível entrar." });
  }
});

// Lista as categorias que já existem no banco.
app.get("/api/categorias", async (_req, res) => {
  try {
    const resultado = await pool.query(
      "SELECT id_categoria, nome FROM categoria ORDER BY nome"
    );
    res.json(resultado.rows);
  } catch (erro) {
    console.error(erro);
    res.status(500).json({ erro: "Erro ao carregar categorias." });
  }
});

// Retorna uma pergunta aleatória ainda não respondida pelo jogador.
// A resposta correta não é enviada ao navegador.
app.get("/api/pergunta", autenticar, async (req, res) => {
  const categoria = req.query.categoria ? Number(req.query.categoria) : null;

  if (categoria !== null && (!Number.isInteger(categoria) || categoria <= 0)) {
    return res.status(400).json({ erro: "Categoria inválida." });
  }

  try {
    const valores = [req.jogador.id_jogador];
    let filtroCategoria = "";

    if (categoria !== null) {
      valores.push(categoria);
      filtroCategoria = `AND p.id_categoria = $${valores.length}`;
    }

    const resultado = await pool.query(
      `SELECT p.id_pergunta, p.enunciado, c.nome AS categoria,
              a.id_alternativa, a.identificador, a.texto
       FROM pergunta p
       JOIN categoria c ON c.id_categoria = p.id_categoria
       JOIN alternativa a ON a.id_pergunta = p.id_pergunta
       WHERE NOT EXISTS (
         SELECT 1 FROM pontuacao po
         WHERE po.id_pergunta = p.id_pergunta
           AND po.id_jogador = $1
       )
       ${filtroCategoria}
       ORDER BY RANDOM()
       LIMIT 1`,
      valores
    );

    if (!resultado.rowCount) {
      return res.json({ fim: true, mensagem: "Você respondeu a todas as perguntas desta seleção!" });
    }

    const primeira = resultado.rows[0];
    const pergunta = {
      id_pergunta: primeira.id_pergunta,
      enunciado: primeira.enunciado,
      categoria: primeira.categoria,
      alternativas: []
    };

    // Busca as quatro alternativas da pergunta selecionada.
    const alternativas = await pool.query(
      `SELECT id_alternativa, identificador, texto
       FROM alternativa
       WHERE id_pergunta = $1
       ORDER BY identificador`,
      [pergunta.id_pergunta]
    );

    pergunta.alternativas = alternativas.rows;
    res.json(pergunta);
  } catch (erro) {
    console.error(erro);
    res.status(500).json({ erro: "Erro ao buscar pergunta." });
  }
});

// Verifica a alternativa no servidor e grava a pontuação.
app.post("/api/responder", autenticar, async (req, res) => {
  const idPergunta = Number(req.body.id_pergunta);
  const idAlternativa = Number(req.body.id_alternativa);

  if (!Number.isInteger(idPergunta) || !Number.isInteger(idAlternativa)) {
    return res.status(400).json({ erro: "Pergunta ou alternativa inválida." });
  }

  const client = await pool.connect();

  try {
    await client.query("BEGIN");

    const alternativa = await client.query(
      `SELECT id_alternativa, id_pergunta, correta
       FROM alternativa
       WHERE id_alternativa = $1 AND id_pergunta = $2`,
      [idAlternativa, idPergunta]
    );

    if (!alternativa.rowCount) {
      await client.query("ROLLBACK");
      return res.status(400).json({ erro: "Essa alternativa não pertence à pergunta." });
    }

    const correta = alternativa.rows[0].correta;
    const pontos = correta ? 10 : 0;

    await client.query(
      `INSERT INTO pontuacao
         (valor_pontos, id_jogador, id_pergunta, id_alternativa)
       VALUES ($1, $2, $3, $4)`,
      [pontos, req.jogador.id_jogador, idPergunta, idAlternativa]
    );

    const gabarito = await client.query(
      `SELECT identificador, texto
       FROM alternativa
       WHERE id_pergunta = $1 AND correta = TRUE`,
      [idPergunta]
    );

    await client.query("COMMIT");

    res.json({
      correta,
      pontos,
      resposta_correta: gabarito.rows[0] || null,
      mensagem: correta ? "Resposta correta! Você ganhou 10 pontos." : "Resposta incorreta. Confira a resposta correta."
    });
  } catch (erro) {
    await client.query("ROLLBACK");

    if (erro.code === "23505") {
      return res.status(409).json({ erro: "Você já respondeu a esta pergunta." });
    }

    console.error(erro);
    res.status(500).json({ erro: "Não foi possível salvar sua resposta." });
  } finally {
    client.release();
  }
});

// Placar do jogador autenticado.
app.get("/api/placar", autenticar, async (req, res) => {
  try {
    const resultado = await pool.query(
      `SELECT COALESCE(SUM(valor_pontos), 0)::INTEGER AS pontos,
              COUNT(*)::INTEGER AS respondidas,
              COUNT(*) FILTER (WHERE valor_pontos > 0)::INTEGER AS acertos
       FROM pontuacao
       WHERE id_jogador = $1`,
      [req.jogador.id_jogador]
    );
    res.json(resultado.rows[0]);
  } catch (erro) {
    console.error(erro);
    res.status(500).json({ erro: "Não foi possível carregar o placar." });
  }
});

app.get("*", (_req, res) => {
  res.sendFile(path.join(__dirname, "public", "index.html"));
});

app.listen(PORT, async () => {
  try {
    await pool.query("SELECT 1");
    console.log(`CyberQuiz rodando em http://localhost:${PORT}`);
    console.log("Conexão com PostgreSQL realizada.");
  } catch (erro) {
    console.error("Servidor iniciou, mas não conectou ao PostgreSQL:", erro.message);
    console.error("Confira as configurações do arquivo .env.");
  }
});
