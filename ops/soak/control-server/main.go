// Servidor de CONTROLE para o experimento de morte de host.
//
// Ele existe por uma razão só: responder às mesmas rotas, com corpos do mesmo
// tamanho, SEM usar io_uring. O net/http do Go usa epoll e threads. Se o host
// morre sob carga com o Druse e sobrevive com este, a diferença aponta para o
// candidato (H-B do pré-registro). Se morre com os dois, aponta para o ambiente
// (H-A).
//
// ISTO NÃO É UMA COMPARAÇÃO DE PERFORMANCE, E NÃO PODE SER REPORTADA COMO UMA.
// O §8 do pré-registro do soak proíbe comparar com pares sem um harness que
// prove trabalho equivalente, e este harness NÃO prova isso — ele iguala carga
// OFERECIDA e tamanho de resposta, que é o que a pergunta sobre o host precisa.
// Qualquer número de latência ou vazão daqui é inadmissível como comparação.
//
//   uso: control-server PORTA
package main

import (
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"time"
)

type MediumItem struct {
	ID     int     `json:"id"`
	Name   string  `json:"name"`
	Score  float64 `json:"score"`
	Active bool    `json:"active"`
}

type MediumDocument struct {
	RequestID string       `json:"request_id"`
	Items     []MediumItem `json:"items"`
	Tags      []string     `json:"tags"`
}

var (
	doc      MediumDocument
	docBytes []byte
	blob64k  []byte
	blob1m   []byte
)

func main() {
	port := "8080"
	if len(os.Args) > 1 {
		port = os.Args[1]
	}

	// Mesma forma do ops/soak/soak-server/main.odin: 64 itens, 6 tags.
	items := make([]MediumItem, 64)
	for i := range items {
		items[i] = MediumItem{
			ID:     i + 1,
			Name:   "item-abcdefghijklmnop",
			Score:  float64(i) + 1.5,
			Active: true,
		}
	}
	doc = MediumDocument{
		RequestID: "req-0123456789abcdef",
		Items:     items,
		Tags:      []string{"alpha", "beta", "gamma", "delta", "epsilon", "zeta"},
	}
	var err error
	docBytes, err = json.Marshal(doc)
	if err != nil {
		fmt.Fprintf(os.Stderr, "control-server: nao consegui serializar o documento: %v\n", err)
		os.Exit(1)
	}

	// Mesmo preenchimento do fill_response: 'a' + i%23.
	blob64k = make([]byte, 64*1024)
	for i := range blob64k {
		blob64k[i] = byte('a' + i%23)
	}
	// /bytes/1m existe porque a injecao slow_readers do run-soak.sh bate nela:
	// 24 conexoes que pedem 1 MiB e leem devagar. Sem esta rota o braco de
	// controle receberia 404 onde o Druse entrega um corpo grande, e a carga
	// deixaria de ser equivalente exatamente na injecao que mais estressa.
	blob1m = make([]byte, 1024*1024)
	for i := range blob1m {
		blob1m[i] = byte('a' + i%23)
	}

	mux := http.NewServeMux()

	mux.HandleFunc("/health", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/plain; charset=utf-8")
		w.Write([]byte("ok"))
	})

	mux.HandleFunc("/tiny", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/plain; charset=utf-8")
		w.Write([]byte("pong"))
	})

	mux.HandleFunc("/json/medium", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		w.Write(docBytes)
	})

	mux.HandleFunc("/json/medium/decode", func(w http.ResponseWriter, r *http.Request) {
		body, err := io.ReadAll(io.LimitReader(r.Body, 8<<20))
		if err != nil {
			w.WriteHeader(http.StatusBadRequest)
			return
		}
		var in MediumDocument
		if err := json.Unmarshal(body, &in); err != nil {
			w.WriteHeader(http.StatusBadRequest)
			return
		}
		w.WriteHeader(http.StatusNoContent)
	})

	mux.HandleFunc("/bytes/64k", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/octet-stream")
		w.Write(blob64k)
	})

	mux.HandleFunc("/bytes/1m", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/octet-stream")
		w.Write(blob1m)
	})

	mux.HandleFunc("/wait/40ms", func(w http.ResponseWriter, r *http.Request) {
		time.Sleep(40 * time.Millisecond)
		w.Header().Set("Content-Type", "text/plain; charset=utf-8")
		w.Write([]byte("done"))
	})

	srv := &http.Server{
		Addr:    ":" + port,
		Handler: mux,
	}
	fmt.Fprintf(os.Stderr, "control-server: escutando em :%s (net/http, epoll, SEM io_uring)\n", port)
	if err := srv.ListenAndServe(); err != nil {
		fmt.Fprintf(os.Stderr, "control-server: %v\n", err)
		os.Exit(1)
	}
}
