// Servidor mínimo para medir o tempo de inicialização COM upload habilitado.
//
// A medição de 2026-08-04 (evidence/2026-08-04-startup-window/) mediu o
// soak-server, que NAO chama enable_upload, e declarou esse limite: ela diz que
// a inicialização genérica é rápida e não diz nada sobre o caminho do ingest --
// que é exatamente o caminho do fixture que falhou.
//
// Este binário fecha a lacuna. argv[1] = porta, argv[2] = diretório de spool.
package upstartup

import "core:os"
import "core:strconv"
import web "druse:web"

app: web.App

handler :: proc(ctx: ^web.Context) {
	web.text(ctx, .OK, "ok")
}

main :: proc() {
	port := 47001
	if len(os.args) > 1 {
		if v, ok := strconv.parse_int(os.args[1]); ok {port = v}
	}
	dir := "/tmp/druse-upstart"
	if len(os.args) > 2 {dir = os.args[2]}

	app = web.app()
	defer web.destroy(&app)
	web.enable_upload(&app, web.Upload_Config{dir = dir, per_upload_quota = 1 << 20, max_concurrent = 8})
	web.get(&app, "/ping", handler)
	web.serve(&app, port)
}
