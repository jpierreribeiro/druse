#!/usr/bin/env python3
"""Compara os dois braços do A/B contra o critério §4 do pré-registro.

    uso: analyze-kernel-watch.py --druse DIR --control DIR [--json]
         analyze-kernel-watch.py --self-test

POR QUE ESTE ARQUIVO EXISTE, E POR QUE AGORA.

O §4 do `HOST-DEATH-preregistration.md` exige, para declarar H-B, um contador de
kernel **monotônico** cujo valor **projetado alcance um limite do sistema** dentro
da ordem de grandeza do tempo até a morte. Isso é uma regra, e uma regra aplicada
no olho depois de ver a curva não é uma regra.

Escrito **antes de existir qualquer dado do A/B** — os dois únicos ensaios que
existem são de 2 min na máquina do autor, e servem para provar o instrumento, não
o produto. Um revisor pode rodar este script nos dados quando eles existirem e
tem de chegar ao mesmo veredito. Se chegar a outro, a regra foi violada.

O QUE ELE NÃO FAZ. Não decide se o Druse derruba o host: isso exige >= 2 pares e
o braço de controle sobrevivendo, que é a condição 1 do §4 e é sobre MORTE DE
HOST, não sobre contador. Este script responde só a condição 2.
"""
import argparse
import csv
import json
import os
import sys

# Colunas com limite de sistema conhecido. O limite é lido do host quando
# possível; quando não, fica `None` e a coluna é reportada SEM projeção — nunca
# com uma projeção inventada.
LIMITES = {
    "file_nr": ("/proc/sys/fs/file-max", None),
    "mlocked_kib": (None, "RLIMIT_MEMLOCK"),
    "proc_vmpin_kib": (None, "RLIMIT_MEMLOCK"),
    "mem_free_kib": (None, "zero"),
    "slab_kib": (None, "memória total"),
    "sunreclaim_kib": (None, "memória total"),
    "kernel_stack_kib": (None, "memória total"),
    "proc_fds": (None, "RLIMIT_NOFILE"),
    "proc_iouring_fds": (None, "RLIMIT_NOFILE"),
    "proc_threads": (None, "threads-max"),
}

IGNORAR = {"unix_s"}


def ler(caminho):
    with open(caminho, newline="") as fh:
        linhas = list(csv.DictReader(fh))
    if not linhas:
        raise SystemExit(f"{caminho}: vazio — recuso analisar")
    return linhas


def serie(linhas, coluna):
    """Devolve (tempos, valores) descartando NA. NA é ausência, não zero."""
    t, v = [], []
    for linha in linhas:
        bruto = linha.get(coluna, "")
        if bruto in ("NA", "", None):
            continue
        try:
            v.append(float(bruto))
            t.append(float(linha["unix_s"]))
        except (ValueError, KeyError):
            continue
    return t, v


def inclinacao(t, v):
    """Mínimos quadrados, em unidades por hora."""
    n = len(v)
    if n < 3:
        return None
    mt = sum(t) / n
    mv = sum(v) / n
    num = sum((t[i] - mt) * (v[i] - mv) for i in range(n))
    den = sum((t[i] - mt) ** 2 for i in range(n))
    if den == 0:
        return None
    return (num / den) * 3600.0


def fracao_nao_decrescente(v):
    """Quanto da série nunca desce. Monotonicidade tolerante a ruído."""
    if len(v) < 2:
        return None
    passos = [v[i + 1] - v[i] for i in range(len(v) - 1)]
    return sum(1 for p in passos if p >= 0) / len(passos)


def analisar(linhas_d, linhas_c, minutos_ate_morte):
    colunas = [c for c in linhas_d[0].keys() if c not in IGNORAR]
    achados, tabela = [], []

    for coluna in colunas:
        td, vd = serie(linhas_d, coluna)
        tc, vc = serie(linhas_c, coluna)
        if len(vd) < 3:
            tabela.append({"coluna": coluna, "estado": "amostras insuficientes no braço druse"})
            continue

        sd = inclinacao(td, vd)
        sc = inclinacao(tc, vc) if len(vc) >= 3 else None
        md = fracao_nao_decrescente(vd)

        linha = {
            "coluna": coluna,
            "druse_min": min(vd), "druse_max": max(vd),
            "druse_inclinacao_por_hora": sd,
            "druse_fracao_nao_decrescente": md,
            "control_inclinacao_por_hora": sc,
        }

        # A regra do §4, aplicada tal como escrita:
        #   (a) monotônico no braço Druse
        #   (b) NÃO monotônico/crescente no controle
        #   (c) projetado a alcançar um limite na ordem do tempo até a morte
        cresce_no_druse = sd is not None and sd > 0 and md is not None and md >= 0.90
        cresce_no_controle = sc is not None and sc > 0
        linha["cresce_no_druse"] = cresce_no_druse
        linha["cresce_no_controle"] = cresce_no_controle

        if cresce_no_druse and not cresce_no_controle:
            limite_arquivo, limite_nome = LIMITES.get(coluna, (None, None))
            limite = None
            if limite_arquivo and os.path.exists(limite_arquivo):
                try:
                    limite = float(open(limite_arquivo).read().strip())
                except (ValueError, OSError):
                    limite = None
            if limite:
                folga = limite - max(vd)
                horas = folga / sd if sd > 0 else None
                linha["limite"] = limite
                linha["horas_ate_o_limite"] = horas
                dentro = horas is not None and horas <= (minutos_ate_morte / 60.0) * 10
                linha["dentro_da_ordem_de_grandeza"] = dentro
                if dentro:
                    achados.append(linha)
            else:
                # Sem limite legível NÃO é "passou": é indeterminado, e aparece.
                linha["limite"] = None
                linha["limite_nome"] = limite_nome
                linha["dentro_da_ordem_de_grandeza"] = None
                linha["nota"] = ("cresce só no Druse, mas o limite do sistema não foi lido — "
                                 "INDETERMINADO, não aprovado")
                achados.append(linha)
        tabela.append(linha)

    return achados, tabela


def self_test():
    """G2: um analisador que nunca acusou é um analisador não testado."""
    import tempfile

    def escrever(caminho, valores):
        with open(caminho, "w", newline="") as fh:
            fh.write("unix_s,file_nr,proc_fds\n")
            for i, v in enumerate(valores):
                fh.write(f"{1000 + i * 5},{int(v)},10\n")

    with tempfile.TemporaryDirectory() as d:
        subindo = os.path.join(d, "sobe.csv")
        plano = os.path.join(d, "plano.csv")
        ruidoso = os.path.join(d, "ruido.csv")

        limite = float(open("/proc/sys/fs/file-max").read().strip())
        # Sobe até bater no limite em ~1 h, com 720 amostras de 5 s.
        base = limite * 0.5
        passo = (limite - base) / 720
        escrever(subindo, [base + i * passo for i in range(720)])
        escrever(plano, [base] * 720)
        escrever(ruidoso, [base + (37 if i % 2 else -37) for i in range(720)])

        print("== controle positivo: série monotônica rumo ao limite TEM de acusar ==")
        achados, _ = analisar(ler(subindo), ler(plano), 60)
        nomes = [a["coluna"] for a in achados]
        if "file_nr" not in nomes:
            print(f"  FALHOU: não acusou. achados={nomes}", file=sys.stderr)
            return 1
        print(f"  PASS: acusou {nomes}")

        print("== mutante 1: série PLANA nos dois braços NÃO pode acusar ==")
        achados, _ = analisar(ler(plano), ler(plano), 60)
        if achados:
            print(f"  FALHOU: acusou {[a['coluna'] for a in achados]} numa série plana", file=sys.stderr)
            return 1
        print("  PASS: não acusou")

        print("== mutante 2: ruído sem tendência NÃO pode acusar ==")
        achados, _ = analisar(ler(ruidoso), ler(plano), 60)
        if achados:
            print(f"  FALHOU: acusou {[a['coluna'] for a in achados]} em ruído", file=sys.stderr)
            return 1
        print("  PASS: não acusou")

        print("== mutante 3: se o CONTROLE também sobe, NÃO é achado do candidato ==")
        achados, _ = analisar(ler(subindo), ler(subindo), 60)
        if achados:
            print(f"  FALHOU: acusou {[a['coluna'] for a in achados]} com os dois braços subindo", file=sys.stderr)
            return 1
        print("  PASS: não acusou — sobe nos dois, logo não separa os braços")

    print("\nanalyze-kernel-watch: QUALIFICADO")
    return 0


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--druse")
    p.add_argument("--control")
    p.add_argument("--minutes-to-death", type=float, default=75.0,
                   help="tempo até a morte observado; o terceiro host morreu em 1h15")
    p.add_argument("--json", action="store_true")
    p.add_argument("--self-test", action="store_true")
    a = p.parse_args()

    if a.self_test:
        return self_test()
    if not a.druse or not a.control:
        p.error("--druse e --control são obrigatórios")

    ld = ler(os.path.join(a.druse, "kernel-watch.csv"))
    lc = ler(os.path.join(a.control, "kernel-watch.csv"))
    achados, tabela = analisar(ld, lc, a.minutes_to_death)

    saida = {
        "schema": "kernel-watch-analysis/1",
        "amostras_druse": len(ld),
        "amostras_control": len(lc),
        "minutos_ate_morte_usados": a.minutes_to_death,
        "condicao_2_do_paragrafo_4": "satisfeita" if achados else "NAO satisfeita",
        "achados": achados,
        "tabela": tabela,
        "aviso": ("A condição 1 do §4 — o host do Druse morre e o do controle sobrevive, "
                  "em >= 2 pares — NÃO é avaliada aqui. Sem ela, H-B não é declarada."),
    }
    if a.json:
        print(json.dumps(saida, indent=2, ensure_ascii=False))
    else:
        print(f"condição 2 do §4: {saida['condicao_2_do_paragrafo_4']}")
        for achado in achados:
            print(f"  {achado['coluna']}: {achado.get('nota', '')} "
                  f"inclinação={achado['druse_inclinacao_por_hora']:.1f}/h")
        print(f"\n{saida['aviso']}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
