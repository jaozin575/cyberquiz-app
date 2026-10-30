const auth = document.querySelector("#auth");
const jogo = document.querySelector("#jogo");
const formAuth = document.querySelector("#formAuth");
const mensagemAuth = document.querySelector("#mensagemAuth");
const nomeInput = document.querySelector("#nome");
const emailInput = document.querySelector("#email");
const senhaInput = document.querySelector("#senha");
const abaLogin = document.querySelector("#abaLogin");
const abaCadastro = document.querySelector("#abaCadastro");
const btnAuth = document.querySelector("#btnAuth");
const nomeObrigatorio = document.querySelector("#nomeObrigatorio");

let modo = "login";
let token = "";
let jogador = null;
let perguntaAtual = null;
let respondida = false;

function mostrarMensagem(elemento, texto, tipo = "") {
  elemento.textContent = texto;
  elemento.className = `mensagem ${tipo}`;
}

function api(url, opcoes = {}) {
  const headers = { ...(opcoes.headers || {}) };
  if (opcoes.body) headers["Content-Type"] = "application/json";
  if (token) headers.Authorization = `Bearer ${token}`;
  return fetch(url, { ...opcoes, headers });
}

function escolherModo(novoModo) {
  modo = novoModo;
  const cadastro = modo === "cadastro";
  abaLogin.classList.toggle("ativa", !cadastro);
  abaCadastro.classList.toggle("ativa", cadastro);
  nomeInput.required = cadastro;
  nomeInput.parentElement?.classList.toggle("escondido", false);
  nomeInput.classList.toggle("escondido", !cadastro);
  nomeInput.previousElementSibling?.classList.toggle("escondido", !cadastro);
  nomeObrigatorio.classList.toggle("escondido", !cadastro);
  btnAuth.textContent = cadastro ? "Criar conta" : "Entrar";
  senhaInput.autocomplete = cadastro ? "new-password" : "current-password";
  mostrarMensagem(mensagemAuth, "");
}

abaLogin.addEventListener("click", () => escolherModo("login"));
abaCadastro.addEventListener("click", () => escolherModo("cadastro"));

formAuth.addEventListener("submit", async (evento) => {
  evento.preventDefault();
  btnAuth.disabled = true;
  mostrarMensagem(mensagemAuth, "Aguarde...");
  const dados = { email: emailInput.value, senha: senhaInput.value };
  if (modo === "cadastro") dados.nome = nomeInput.value;

  try {
    const resposta = await fetch(`/api/${modo}`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(dados)
    });
    const corpo = await resposta.json();
    if (!resposta.ok) throw new Error(corpo.erro || "Não foi possível continuar.");

    token = corpo.token;
    jogador = corpo.jogador;
    auth.classList.add("escondido");
    jogo.classList.remove("escondido");
    document.querySelector("#boasVindas").textContent = `Olá, ${jogador.nome}!`;
    await carregarCategorias();
    await atualizarPlacar();
    mostrarMensagem(document.querySelector("#mensagemJogo"), "Escolha uma categoria e comece a jogar.");
  } catch (erro) {
    mostrarMensagem(mensagemAuth, erro.message);
  } finally {
    btnAuth.disabled = false;
  }
});

async function carregarCategorias() {
  const seletor = document.querySelector("#categoria");
  const resposta = await api("/api/categorias");
  const categorias = await resposta.json();
  seletor.innerHTML = '<option value="">Todas as categorias</option>';
  categorias.forEach(categoria => {
    const opcao = document.createElement("option");
    opcao.value = categoria.id_categoria;
    opcao.textContent = categoria.nome;
    seletor.appendChild(opcao);
  });
}

async function atualizarPlacar() {
  const resposta = await api("/api/placar");
  if (!resposta.ok) return;
  const placar = await resposta.json();
  document.querySelector("#pontos").textContent = placar.pontos;
  document.querySelector("#respondidas").textContent = placar.respondidas;
  document.querySelector("#acertos").textContent = placar.acertos;
}

document.querySelector("#btnCarregar").addEventListener("click", carregarPergunta);
document.querySelector("#btnProxima").addEventListener("click", carregarPergunta);

async function carregarPergunta() {
  respondida = false;
  perguntaAtual = null;
  const area = document.querySelector("#areaPergunta");
  const mensagem = document.querySelector("#mensagemJogo");
  const btnCarregar = document.querySelector("#btnCarregar");
  btnCarregar.disabled = true;
  mostrarMensagem(mensagem, "Carregando pergunta...");
  document.querySelector("#resultado").textContent = "";
  document.querySelector("#resultado").className = "resultado";
  document.querySelector("#btnProxima").classList.add("escondido");

  try {
    const categoria = document.querySelector("#categoria").value;
    const url = categoria ? `/api/pergunta?categoria=${encodeURIComponent(categoria)}` : "/api/pergunta";
    const resposta = await api(url);
    const corpo = await resposta.json();
    if (!resposta.ok) throw new Error(corpo.erro || "Erro ao carregar pergunta.");

    if (corpo.fim) {
      area.classList.add("escondido");
      mostrarMensagem(mensagem, corpo.mensagem);
      return;
    }

    perguntaAtual = corpo;
    document.querySelector("#nomeCategoria").textContent = corpo.categoria;
    document.querySelector("#enunciado").textContent = corpo.enunciado;
    const alternativas = document.querySelector("#alternativas");
    alternativas.replaceChildren();

    corpo.alternativas.forEach((alternativa, indice) => {
      const label = document.createElement("label");
      label.className = "opcao";
      const input = document.createElement("input");
      input.type = "radio";
      input.name = "alternativa";
      input.value = alternativa.id_alternativa;
      input.required = true;
      const texto = document.createElement("span");
      texto.textContent = `${alternativa.identificador}. ${alternativa.texto}`;
      label.append(input, texto);
      alternativas.appendChild(label);
    });

    document.querySelector("#btnResponder").disabled = false;
    area.classList.remove("escondido");
    mostrarMensagem(mensagem, "");
  } catch (erro) {
    mostrarMensagem(mensagem, erro.message);
  } finally {
    btnCarregar.disabled = false;
  }
}

document.querySelector("#formResposta").addEventListener("submit", async (evento) => {
  evento.preventDefault();
  if (!perguntaAtual || respondida) return;

  const selecionada = document.querySelector('input[name="alternativa"]:checked');
  if (!selecionada) {
    document.querySelector("#resultado").textContent = "Selecione uma alternativa.";
    return;
  }

  const btnResponder = document.querySelector("#btnResponder");
  btnResponder.disabled = true;

  try {
    const resposta = await api("/api/responder", {
      method: "POST",
      body: JSON.stringify({
        id_pergunta: perguntaAtual.id_pergunta,
        id_alternativa: Number(selecionada.value)
      })
    });
    const corpo = await resposta.json();
    if (!resposta.ok) throw new Error(corpo.erro || "Não foi possível registrar a resposta.");

    respondida = true;
    const resultado = document.querySelector("#resultado");
    resultado.className = `resultado ${corpo.correta ? "ok" : "erro"}`;
    resultado.textContent = `${corpo.mensagem} ${corpo.resposta_correta ? `Resposta correta: ${corpo.resposta_correta.identificador}. ${corpo.resposta_correta.texto}` : ""}`;
    document.querySelectorAll('input[name="alternativa"]').forEach(input => input.disabled = true);
    document.querySelector("#btnProxima").classList.remove("escondido");
    await atualizarPlacar();
  } catch (erro) {
    mostrarMensagem(document.querySelector("#mensagemJogo"), erro.message);
    btnResponder.disabled = false;
  }
});

document.querySelector("#btnSair").addEventListener("click", () => {
  token = "";
  jogador = null;
  perguntaAtual = null;
  auth.classList.remove("escondido");
  jogo.classList.add("escondido");
  formAuth.reset();
  escolherModo("login");
  mostrarMensagem(mensagemAuth, "Você saiu da conta.");
});