# Regras Imobiliária — Forel

Pacote de regras para organizar documentos de imóveis brasileiros (matrícula/RGI,
IPTU, escritura, locação, condomínio, aluguel, certidão) a partir do texto lido
por OCR — imagens (JPEG/PNG/HEIC) e PDFs escaneados.

## Instalação

1. Adicione a pasta raiz dos imóveis (ex. `/Volumes/edgard/00-Imobiliaria/Imoveis`)
   como pasta monitorada no Forel — as regras usam recursão ilimitada.
2. Regras → **Importar** → `Rules/Imobiliaria.forelrules`.
3. As regras importam **desativadas**. Rode **Dry Run** na pasta `Documentos`
   de um imóvel, confira os nomes previstos por arquivo, e só então ative.

## Regras

| Ordem | Nome | Efeito |
|---|---|---|
| 0 | RGI — página com folha identificada | tag `rgi` + comentário com o cartório + rename `RGI-<matrícula>-fls<NN>-<N>RI.<ext>` |
| 1 | RGI — página sem folha identificada | fallback (sem "fls." legível): `RGI-<matrícula>-<N>RI.<ext>` |
| 2 | IPTU — exercício e inscrição | tag `iptu` + rename `IPTU-<ano>-<inscrição>.<ext>` |
| 3 | Escritura pública | tag `escritura` |
| 4 | Contrato de locação | tag `locacao` |
| 5 | Boleto ou taxa de condomínio | tag `condominio` |
| 6 | Recibo de aluguel | tag `aluguel` |
| 7 | Certidão de ônus | tag `certidao` |

A ordem das ações nas regras de RGI é deliberada — **tag → comentário → rename** —
porque o Dry Run simula o rename sem mover o arquivo; ações que leem o conteúdo
(`{content:…}`) precisam executar antes de qualquer ação que mude o caminho.

## Como calibrar contra documentos reais

Os regexes foram calibrados contra OCR de documentos reais do 9º Ofício do Rio
(incluindo ruído: "MATRICILA" por MATRÍCULA, "ICHA" por FICHA, "IMOVEIS" sem
acento, cartório em ordem invertida). Para revalidar com documentos novos:

```bash
FOREL_REAL_DOC_DIR="/caminho/para/Documentos" \
  swift test --filter realDocumentsDryRunWhenProvided
```

O teste imprime o texto OCR de cada arquivo e o veredito de cada regra
(comoções planejadas incluídas). Dica prática: abra a imagem no Preview e tente
selecionar o texto — o Live Text usa o mesmo motor de OCR do Forel; o que você
consegue selecionar é o que as regras veem.

## Limitações conhecidas

- **Boleto de condomínio sem a palavra "condomínio"**: boletos identificados só
  pelo cedente (ex. ESTASA) não casam — a regra exige "boleto/recibo/taxa de
  condomínio" para evitar falsos positivos. Ajuste a condição com o nome do seu
  administrador se quiser cobrir esse caso.
- **Matrícula com pontuação variável**: `9.999` vs `10.000` não ordenam
  alfabeticamente; o `|padN` só zera à esquerda capturas puramente numéricas.
- **`contains` não dobra acentos** no Forel — por isso as condições usam regex
  com `(?i)` e classes tolerantes (`im[óo]veis`, `matr[\wÀ-ÿ]{3,9}`).
- Se o OCR não ler a matrícula, o rename falha **visivelmente** no histórico (a
  tag continua aplicada) — nunca é gerado nome incompleto.

## Permissões do macOS (uma vez só)

Rode o fork com `./build.sh dev` (não `swift run`): o bundle é assinado com seu
certificado da keychain, então o macOS lembra a autorização de acesso a volumes
removíveis entre rebuilds. Após o primeiro "Permitir", fica gravado em Ajustes
do Sistema → Privacidade e Segurança → Arquivos e Pastas → Forel.
