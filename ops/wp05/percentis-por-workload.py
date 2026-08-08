#!/usr/bin/env python3
"""Percentis POR WORKLOAD a partir dos CSVs brutos de `lanes-sweep.sh`.

    uso: percentis-por-workload.py RUN_DIR [--json]
         percentis-por-workload.py --self-test

POR QUE ESTE ARQUIVO EXISTE.

`ops/wp05/lanes-sweep.sh` lanca SEIS geradores, um por workload, e cada um
escreve o proprio CSV em `raw/w%03d-<workload>.csv`. O resumo embutido no
harness entao faz:

    for path in glob.glob(os.path.join(out, "raw", "*.csv")):   # os SEIS juntos

**Ele coleta a dimensao por workload e a descarta ao agregar.** O dado por
workload ja existe em disco, em arquivos separados; falta so nao mistura-lo.

E a mistura nao e neutra. O `/wait/40ms` tem piso de 40 ms POR CONSTRUCAO e roda
a 1 req/s contra 960 agregados — 0,104% das amostras. O p999 corta o topo 0,1%.
Os dois numeros coincidem: o `latency_p999_us=40249` do K1 (evidence/
2026-08-05-r2-wp05-knee/fase1/K1.manifest) nao mede degradacao nenhuma, mede a
constante de sleep de um workload que ocupa exatamente aquela faixa do
percentil. Um SLO derivado dali prometeria sobre um `time.sleep`.

O QUE ESTE SCRIPT NAO FAZ: nao toca em `lanes-sweep.sh`. O §5 do
`R2-WP05-knee-preregistration.md` registra aquele harness como usado "sem
modificacao", e reescreve-lo tornaria as corridas anteriores incomparaveis sem
necessidade. Este e um pos-processador: le o mesmo `raw/` e nao grada nada —
mede e registra, como o harness.

O TERCEIRO ESTADO (§8.4 do briefing; a classe de defeito que este repositorio
mais produz). Um instrumento tem de saber dizer "nao consegui perguntar", e
dize-lo alto. Aqui isso e explicito:

  * `raw/` ausente ou sem CSV               -> exit 2, nada impresso como dado
  * workload sem NENHUMA amostra            -> `unknown`, NUNCA `0`
  * workload abaixo do volume planejado     -> `shortfall` marcado no relatorio
  * linha malformada (corrida morta no meio
    deixa a ultima linha truncada)          -> contada e REPORTADA, nao ignorada

Um `0` aqui significa "medi zero". Um `unknown` significa "nao medi". Sao coisas
diferentes e o formato nunca as confunde.
"""

import argparse
import csv
import json
import math
import os
import re
import sys
import tempfile

# `w007-json-decode.csv` -> `json-decode`. O prefixo de onda existe porque cada
# rajada escreve o proprio arquivo; a onda nao e uma dimensao do SLO, o workload
# e. Agrupar por workload junta as ondas e mantem os seis separados.
NOME_RAW = re.compile(r"^w(\d+)-(?P<workload>.+)\.csv$")

# Os seis que `launch_generators` sobe, com a chave de taxa correspondente no
# manifest.txt. A reconciliacao planejado-vs-completado depende deste mapa: sem
# ele, um gerador que morreu no segundo 1 e indistinguivel de um que rodou.
TAXA_DE = {
    "health": "health_rate",
    "tiny": "tiny_rate",
    "json-encode": "json_encode_rate",
    "json-decode": "json_decode_rate",
    "bytes-64k": "bytes_64k_rate",
    "wait-40ms": "wait_40ms_rate",
}

# Workloads cujo percentil NAO descreve o servidor. `/wait/40ms` dorme 40 ms por
# construcao: o p99 dele mede o sleep, nao o framework. Ele continua sendo
# medido e reportado — ele pertence ao mix e carrega lane — mas sai marcado, para
# que ninguem derive SLO de latencia a partir dele por distracao.
PISO_SINTETICO_MS = {"wait-40ms": 40}

# Quanto o volume completado pode ficar abaixo do planejado antes de a celula
# virar suspeita. Gerador de taxa aberta nao entrega exatamente rate*duration;
# 2% cobre jitter de escalonamento sem cobrir um gerador que morreu.
TOLERANCIA_SHORTFALL = 0.02


class NaoConsegui(Exception):
    """O terceiro estado. Levantada quando o dado nao pode ser lido — jamais
    convertida em numero."""


def percentil(ordenados, p):
    """Nearest-rank: indice = ceil(p * N) - 1, 0-based.

    O resumo embutido no harness usa `lat[min(len-1, int(len*p))]`, que e
    floor(N*p) — um degrau acima do rank correto. Em 288 mil amostras a
    diferenca e invisivel; em uma celula pequena, nao e. Um SLO e um numero que
    alguem vai contestar, entao ele usa a definicao, nao a aproximacao.

    Devolve None (nao -1, nao 0) quando nao ha amostra: um sentinela numerico
    entra em planilha e vira dado.
    """
    if not ordenados:
        return None
    idx = max(0, math.ceil(p * len(ordenados)) - 1)
    return ordenados[idx]


def ler_manifest(run_dir):
    """As taxas planejadas. Ausencia do manifest nao e fatal — sem ele apenas
    nao ha reconciliacao, e o relatorio diz isso em vez de omitir a coluna."""
    caminho = os.path.join(run_dir, "manifest.txt")
    if not os.path.isfile(caminho):
        return None
    campos = {}
    with open(caminho) as fh:
        for linha in fh:
            if "=" in linha:
                k, _, v = linha.partition("=")
                campos[k.strip()] = v.strip()
    return campos


def ler_workloads(run_dir):
    """Agrupa os CSVs de `raw/` por workload, SEM misturar.

    Levanta NaoConsegui quando nao ha o que ler — o caso em que o harness
    embutido imprimiria `-1` e sairia 0.
    """
    raw = os.path.join(run_dir, "raw")
    if not os.path.isdir(raw):
        raise NaoConsegui(f"{raw} nao existe — esta corrida nao guardou CSV bruto")

    por_workload = {}
    for nome in sorted(os.listdir(raw)):
        m = NOME_RAW.match(nome)
        if not m:
            continue
        por_workload.setdefault(m.group("workload"), []).append(os.path.join(raw, nome))

    if not por_workload:
        raise NaoConsegui(
            f"{raw} nao contem nenhum CSV no padrao w<NNN>-<workload>.csv"
        )
    return por_workload


def medir(caminhos):
    """Uma celula. Conta 2xx, nao-2xx, falhas de transporte e linhas malformadas.

    Uma corrida que morreu no meio deixa a ultima linha truncada. `int()` nela
    levantaria ValueError e derrubaria o script inteiro no fim de um soak de
    12 h — ou, pior, um `except: pass` a descartaria em silencio. Aqui ela e
    CONTADA e sai no relatorio: o leitor ve que houve truncamento e quanto.
    """
    lat, ok, non2xx, falhas, malformadas = [], 0, 0, 0, 0
    for caminho in caminhos:
        with open(caminho, newline="") as fh:
            for row in csv.DictReader(fh):
                try:
                    if row.get("failure_class"):
                        falhas += 1
                        continue
                    status = int(row["status"])
                    ns = int(row["latency_ns"])
                except (TypeError, ValueError, KeyError):
                    malformadas += 1
                    continue
                if 200 <= status < 300:
                    ok += 1
                    lat.append(ns)
                else:
                    non2xx += 1
    lat.sort()
    return lat, ok, non2xx, falhas, malformadas


def analisar(run_dir):
    manifest = ler_manifest(run_dir)
    por_workload = ler_workloads(run_dir)

    duracao = None
    if manifest:
        try:
            duracao = int(manifest.get("duration_s", ""))
        except ValueError:
            duracao = None

    celulas = []
    for workload in sorted(por_workload):
        lat, ok, non2xx, falhas, malformadas = medir(por_workload[workload])

        celula = {
            "workload": workload,
            "arquivos": len(por_workload[workload]),
            "completed_2xx": ok,
            "non_2xx": non2xx,
            "transport_failures": falhas,
            "linhas_malformadas": malformadas,
            # None, nao -1: "nao medi" nao pode entrar numa planilha como numero.
            "p50_us": None if not lat else percentil(lat, 0.50) // 1000,
            "p99_us": None if not lat else percentil(lat, 0.99) // 1000,
            "p999_us": None if not lat else percentil(lat, 0.999) // 1000,
            "piso_sintetico_ms": PISO_SINTETICO_MS.get(workload),
            "estado": "ok" if lat else "unknown",
        }

        # Reconciliacao: um gerador que nunca subiu entrega um CSV vazio (ou
        # nenhum) e, sem esta conta, a celula sai `unknown` sem dizer que era
        # para ter havido 288 mil amostras. Com ela, sai `shortfall` e o
        # relatorio nomeia o tamanho do buraco.
        chave = TAXA_DE.get(workload)
        if manifest and chave and duracao:
            try:
                planejado = int(manifest[chave]) * duracao
            except (KeyError, ValueError):
                planejado = None
            if planejado:
                celula["planejado"] = planejado
                celula["fracao_entregue"] = round((ok + non2xx + falhas) / planejado, 4)
                if (ok + non2xx + falhas) < planejado * (1 - TOLERANCIA_SHORTFALL):
                    celula["estado"] = "shortfall"

        celulas.append(celula)

    return {
        "run_dir": os.path.abspath(run_dir),
        "arm": (manifest or {}).get("arm"),
        "lanes": (manifest or {}).get("lanes"),
        "aggregate_rate": (manifest or {}).get("aggregate_rate"),
        "reconciliacao": "disponivel" if (manifest and duracao) else "indisponivel",
        "celulas": celulas,
    }


def imprimir(rel):
    print(f"run          {rel['run_dir']}")
    print(f"arm          {rel['arm']}   lanes={rel['lanes']}   agregado={rel['aggregate_rate']}/s")
    print(f"reconciliacao {rel['reconciliacao']}")
    print()
    cab = f"{'workload':<14}{'estado':<11}{'2xx':>10}{'p50us':>9}{'p99us':>9}{'p999us':>9}  nota"
    print(cab)
    print("-" * len(cab))
    for c in rel["celulas"]:
        def n(v):
            return "unknown" if v is None else str(v)
        nota = []
        if c["piso_sintetico_ms"]:
            nota.append(f"PISO {c['piso_sintetico_ms']}ms — nao derive SLO daqui")
        if c["linhas_malformadas"]:
            nota.append(f"{c['linhas_malformadas']} linhas malformadas")
        if c["estado"] == "shortfall":
            nota.append(f"entregou {c['fracao_entregue']:.1%} do planejado")
        if c["transport_failures"]:
            nota.append(f"{c['transport_failures']} falhas de transporte")
        print(
            f"{c['workload']:<14}{c['estado']:<11}{c['completed_2xx']:>10}"
            f"{n(c['p50_us']):>9}{n(c['p99_us']):>9}{n(c['p999_us']):>9}  {'; '.join(nota)}"
        )

    ruins = [c for c in rel["celulas"] if c["estado"] != "ok"]
    print()
    if ruins:
        print(f"NAO LIMPO: {len(ruins)} de {len(rel['celulas'])} celulas nao sao 'ok' "
              f"({', '.join(c['workload'] + '=' + c['estado'] for c in ruins)})")
    else:
        print(f"todas as {len(rel['celulas'])} celulas mediram.")
    return 1 if ruins else 0


# ---------------------------------------------------------------------------
# G2: o instrumento prova a si mesmo ANTES de medir o produto. Um controle
# positivo que fica verde e mutantes que ficam vermelhos PELA RAZAO ESPERADA.
# ---------------------------------------------------------------------------

def _escrever(raw, nome, linhas):
    with open(os.path.join(raw, nome), "w", newline="") as fh:
        fh.write("status,latency_ns,failure_class\n")
        for st, ns, fc in linhas:
            fh.write(f"{st},{ns},{fc}\n")


def _montar(base, taxas, duracao, dados):
    os.makedirs(os.path.join(base, "raw"), exist_ok=True)
    with open(os.path.join(base, "manifest.txt"), "w") as fh:
        fh.write("schema=wp05-burst/1\narm=T\nlanes=4\n")
        fh.write(f"duration_s={duracao}\n")
        for k, v in taxas.items():
            fh.write(f"{k}={v}\n")
    for nome, linhas in dados.items():
        _escrever(os.path.join(base, "raw"), nome, linhas)
    return base


def self_test():
    falhou = 0

    def checa(rotulo, condicao, detalhe=""):
        nonlocal falhou
        print(f"  {'PASS' if condicao else 'FAIL'}  {rotulo}" + (f"  [{detalhe}]" if detalhe and not condicao else ""))
        if not condicao:
            falhou += 1

    taxas = {"health_rate": 10, "wait_40ms_rate": 1}

    with tempfile.TemporaryDirectory() as tmp:
        print("== controle positivo: dois workloads separados TEM de sair separados ==")
        # A razao de existir do script. Misturados, o p99 do conjunto seria
        # arrastado pelo wait-40ms; separados, cada um mostra o proprio.
        base = _montar(
            os.path.join(tmp, "c1"), taxas, 10,
            {
                "w001-health.csv": [(200, 1_000_000, "") for _ in range(100)],
                "w001-wait-40ms.csv": [(200, 40_000_000, "") for _ in range(10)],
            },
        )
        rel = analisar(base)
        cel = {c["workload"]: c for c in rel["celulas"]}
        checa("duas celulas, nao uma", len(rel["celulas"]) == 2, str(len(rel["celulas"])))
        checa("health p99 = 1000us (nao contaminado)", cel["health"]["p99_us"] == 1000, str(cel["health"]["p99_us"]))
        checa("wait-40ms p99 = 40000us (isolado)", cel["wait-40ms"]["p99_us"] == 40000, str(cel["wait-40ms"]["p99_us"]))
        checa("wait-40ms sai marcado com piso sintetico", cel["wait-40ms"]["piso_sintetico_ms"] == 40)
        checa("ambas as celulas 'ok'", all(c["estado"] == "ok" for c in rel["celulas"]))

        print("== mutante 1: celula VAZIA tem de virar 'unknown', nunca 0 ==")
        # O defeito da §8.4 em forma pura: o harness embutido imprimiria -1 e
        # sairia 0. Zero amostras nao e latencia zero.
        base = _montar(
            os.path.join(tmp, "m1"), taxas, 10,
            {
                "w001-health.csv": [],
                "w001-wait-40ms.csv": [(200, 40_000_000, "") for _ in range(10)],
            },
        )
        rel = analisar(base)
        cel = {c["workload"]: c for c in rel["celulas"]}
        checa("health p99 e None (unknown), nao 0", cel["health"]["p99_us"] is None, repr(cel["health"]["p99_us"]))
        checa("health nao fica 'ok'", cel["health"]["estado"] != "ok", cel["health"]["estado"])

        print("== mutante 2: gerador que morreu cedo tem de virar 'shortfall' ==")
        # 10 amostras onde o manifest planejou 100. Sem reconciliacao isto
        # passaria por uma medicao legitima e pequena.
        base = _montar(
            os.path.join(tmp, "m2"), taxas, 10,
            {"w001-health.csv": [(200, 1_000_000, "") for _ in range(10)]},
        )
        rel = analisar(base)
        cel = {c["workload"]: c for c in rel["celulas"]}
        checa("health = shortfall", cel["health"]["estado"] == "shortfall", cel["health"]["estado"])
        checa("a fracao entregue e nomeada", cel["health"]["fracao_entregue"] == 0.1, str(cel["health"].get("fracao_entregue")))

        print("== mutante 3: raw/ ausente tem de GRITAR, nao devolver zero ==")
        vazio = os.path.join(tmp, "m3")
        os.makedirs(vazio)
        try:
            analisar(vazio)
            checa("levantou NaoConsegui", False, "nao levantou")
        except NaoConsegui:
            checa("levantou NaoConsegui", True)

        print("== mutante 4: linha truncada e CONTADA, nao engolida ==")
        # Uma corrida morta no meio deixa a ultima linha pela metade. Nem
        # derrubar o script, nem descartar em silencio.
        base = _montar(
            os.path.join(tmp, "m4"), taxas, 10,
            {"w001-health.csv": [(200, 1_000_000, "") for _ in range(100)]},
        )
        with open(os.path.join(base, "raw", "w001-health.csv"), "a") as fh:
            fh.write("200,not-a-number,\n")
        rel = analisar(base)
        cel = {c["workload"]: c for c in rel["celulas"]}
        checa("1 linha malformada contada", cel["health"]["linhas_malformadas"] == 1, str(cel["health"]["linhas_malformadas"]))
        checa("as 100 boas continuam medidas", cel["health"]["completed_2xx"] == 100, str(cel["health"]["completed_2xx"]))

        print("== mutante 5: nearest-rank, nao floor ==")
        # 10 amostras 1..10 ms. p99 nearest-rank = ceil(0.99*10)-1 = indice 9 =
        # 10 ms. A formula do harness embutido daria floor(10*0.99)=9 tambem
        # aqui, mas em N=100 com p999 a diferenca aparece; este caso trava a
        # definicao para que uma reescrita futura nao a afrouxe.
        base = _montar(
            os.path.join(tmp, "m5"), {"health_rate": 1}, 10,
            {"w001-health.csv": [(200, i * 1_000_000, "") for i in range(1, 11)]},
        )
        rel = analisar(base)
        cel = {c["workload"]: c for c in rel["celulas"]}
        checa("p99 de 1..10ms = 10000us", cel["health"]["p99_us"] == 10000, str(cel["health"]["p99_us"]))
        checa("p50 de 1..10ms = 5000us", cel["health"]["p50_us"] == 5000, str(cel["health"]["p50_us"]))

    print()
    if falhou:
        print(f"SELF-TEST REPROVADO: {falhou} checagens falharam. "
              f"O instrumento nao esta qualificado para medir.")
        return 1
    print("SELF-TEST OK: controle positivo verde, 5 mutantes vermelhos pela razao esperada.")
    return 0


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("run_dir", nargs="?")
    p.add_argument("--json", action="store_true")
    p.add_argument("--self-test", action="store_true")
    a = p.parse_args()

    if a.self_test:
        return self_test()
    if not a.run_dir:
        p.error("run_dir e obrigatorio (ou use --self-test)")

    try:
        rel = analisar(a.run_dir)
    except NaoConsegui as e:
        # exit 2 = "nao consegui perguntar". Distinto de exit 1 = "perguntei e a
        # resposta nao esta limpa" e de exit 0 = "perguntei e esta limpa".
        print(f"NAO CONSEGUI MEDIR: {e}", file=sys.stderr)
        return 2

    if a.json:
        print(json.dumps(rel, indent=2, ensure_ascii=False))
        return 1 if any(c["estado"] != "ok" for c in rel["celulas"]) else 0
    return imprimir(rel)


if __name__ == "__main__":
    sys.exit(main())
