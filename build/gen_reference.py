#!/usr/bin/env python3
"""Generate docs/reference/ from the public ledger and the source doc comments.

Nothing here is typed by hand. The signature of every symbol comes from
build/phase1-public-signatures.txt — the same file the public-API gate enforces
in both directions — and the description comes from the `//` block immediately
above the declaration in web/.

Run with --check to fail when a committed page no longer matches the source.
That is what stops a reference from drifting, which is the only failure mode a
reference really has.
"""
import re, os, sys, glob

LEDGER = 'build/phase1-public-signatures.txt'
OUT = 'docs/reference'

# Every ledger symbol belongs to exactly one page. A symbol missing from this
# map is a hard error, so a new public symbol cannot land undocumented.
AREAS = [
    ('application', 'Application', 'Creating, configuring, serving and stopping.',
     ['App', 'app', 'bare', 'app_with_state', 'destroy', 'serve', 'stop',
      'is_draining', 'limits', 'Limits', 'DEFAULT_LIMITS', 'state',
      'request_state']),
    ('routing', 'Routing', 'Registering routes, grouping them, and middleware.',
     ['get', 'post', 'put', 'patch', 'delete', 'route', 'router', 'Router',
      'mount', 'use', 'next', 'Handler']),
    ('request', 'Request', 'Reading input. Every string here is a view into the request buffer.',
     ['Context', 'Request', 'Method', 'Header_View', 'path', 'path_int',
      'query', 'query_int', 'query_int_opt', 'query_int_or', 'header',
      'bearer_token', 'body', 'form_field', 'form_file', 'Uploaded_File']),
    ('response', 'Response', 'Sending output. One response per request.',
     ['json', 'text', 'bytes', 'ok', 'created', 'no_content', 'set_header',
      'Status', 'bad_request', 'unauthorized', 'forbidden', 'not_found',
      'internal_error']),
    ('streaming', 'Streaming', 'A response the handler does not buffer whole.',
     ['stream', 'Stream', 'stream_send', 'Stream_Send', 'stream_live',
      'stream_close']),
    ('uploads', 'Uploads', 'Bodies spooled to disk instead of held in memory.',
     ['enable_upload', 'upload', 'upload_persist', 'Upload', 'Upload_Config']),
    ('browser', 'Browser and proxy', 'CORS, static files, security headers, and the real client address.',
     ['cors', 'Cors_Options', 'static', 'Static_Options', 'secure_headers',
      'client_ip', 'trust_proxies']),
    ('observability', 'Observability', 'What failed, how often, and what the server is doing.',
     ['observe', 'Framework_Event', 'Framework_Error', 'logger', 'request_id',
      'stats', 'Server_Stats', 'refused_connections']),
    ('testing', 'Testing', 'The separate two-symbol ledger. It cannot grow by borrowing the application budget.',
     ['test_request', 'Recorded_Response']),
]

GUIDE = {  # symbol -> the guide page that teaches it, when one does
    'state': '03-subjects/context-and-state.md', 'request_state': '03-subjects/context-and-state.md',
    'app_with_state': '03-subjects/context-and-state.md',
    'get': '03-subjects/routing.md', 'post': '03-subjects/routing.md',
    'router': '03-subjects/routing.md', 'mount': '04-rules/composition-and-cost.md',
    'use': '05-recipes/write-a-middleware.md', 'next': '05-recipes/write-a-middleware.md',
    'body': '03-subjects/binding.md', 'query_int': '05-recipes/read-a-query-parameter.md',
    'query_int_opt': '05-recipes/read-a-query-parameter.md',
    'query_int_or': '05-recipes/read-a-query-parameter.md',
    'json': '03-subjects/response.md', 'ok': '03-subjects/response.md',
    'bytes': '03-subjects/response.md', 'Status': '03-subjects/response.md',
    'bad_request': '05-recipes/error-responses.md', 'internal_error': '05-recipes/error-responses.md',
    'stream': '05-recipes/stream-a-response.md', 'stream_send': '05-recipes/stream-a-response.md',
    'upload': '05-recipes/accept-a-file-upload.md', 'upload_persist': '05-recipes/accept-a-file-upload.md',
    'cors': '05-recipes/serve-a-browser-app.md', 'client_ip': '05-recipes/serve-a-browser-app.md',
    'observe': '05-recipes/observe-the-framework.md', 'stats': '05-recipes/observe-the-framework.md',
    'test_request': '05-recipes/test-a-handler.md',
    'limits': '03-subjects/limits-and-shutdown.md', 'stop': '03-subjects/limits-and-shutdown.md',
}


def ledger():
    out = {}
    for line in open(LEDGER):
        p = line.rstrip('\n').split('\t')
        if len(p) < 3:
            continue
        name = re.match(r'([A-Za-z_]\w*)', p[2]).group(1)
        out[name] = (p[0], p[1], p[2])
    return out


def summaries():
    """The `//` block above each declaration, up to its first blank comment line.

    The comments in this codebase run long and are structured: a summary
    paragraph, then blocks of rationale. The summary is what a reference wants;
    the rest stays in the source where it is being maintained.
    """
    out = {}
    for f in glob.glob('web/*.odin') + glob.glob('web/testing/*.odin'):
        lines = open(f).read().split('\n')
        for i, line in enumerate(lines):
            m = re.match(r'^([A-Za-z_]\w*)\s*::', line)
            if not m:
                continue
            block, j = [], i - 1
            while j >= 0 and lines[j].startswith('//'):
                block.append(lines[j][2:].strip())
                j -= 1
            block.reverse()
            para = []
            for b in block:
                if not b and para:
                    break
                if b:
                    para.append(b)
            if para:
                out.setdefault(m.group(1), ' '.join(para))
    return out


def page(slug, title, blurb, names, L, S):
    o = [f'# {title}', '', blurb, '',
         'Generated from `build/phase1-public-signatures.txt` and the source. Do',
         'not edit by hand — run `build/gen_reference.py`.', '']
    for n in names:
        led, kind, sig = L[n]
        o.append(f'## `{n}`')
        o.append('')
        o.append('```odin')
        o.append(sig)
        o.append('```')
        o.append('')
        if led == 'test-support':
            o.append('*Test-support ledger.*')
            o.append('')
        text = S.get(n)
        if text:
            o.append(text if len(text) < 600 else text[:600].rsplit(' ', 1)[0] + ' …')
            o.append('')
        if n in GUIDE:
            o.append(f'Taught in [`{GUIDE[n]}`](../guide/{GUIDE[n]}).')
            o.append('')
    return '\n'.join(o).rstrip() + '\n'


def main():
    L, S = ledger(), summaries()
    assigned = {n for _, _, _, ns in AREAS for n in ns}
    missing = set(L) - assigned
    extra = assigned - set(L)
    if missing or extra:
        if missing:
            print('ledger symbols with no reference page:', ', '.join(sorted(missing)))
        if extra:
            print('reference names not in the ledger:', ', '.join(sorted(extra)))
        return 1

    os.makedirs(OUT, exist_ok=True)
    check = '--check' in sys.argv
    bad = []
    for slug, title, blurb, names in AREAS:
        path = f'{OUT}/{slug}.md'
        new = page(slug, title, blurb, names, L, S)
        if check:
            if not os.path.exists(path) or open(path).read() != new:
                bad.append(path)
        else:
            open(path, 'w').write(new)

    index = ['# Reference', '',
             'Every symbol in the public ledger, with its exact signature.', '',
             'This is the lookup. For how to *use* something, the guide is',
             '[`../guide/README.md`](../guide/README.md).', '',
             'The ledger is enforced in both directions: a missing symbol and an extra',
             'symbol are equally a build failure. So this page is the whole surface —',
             'if something is not here, it does not exist.', '', '| Page | |', '|---|---|']
    for slug, title, blurb, names in AREAS:
        index.append(f'| [{title}]({slug}.md) | {blurb} |')
    counts = {}
    for n, (led, kind, _) in L.items():
        counts[kind] = counts.get(kind, 0) + 1
    index += ['', f'**{len(L)} symbols**: {counts.get("proc",0)} procedures, '
              f'{counts.get("type",0)} types, {counts.get("const",0)} constant. '
              'The application ledger holds 80 and the test-support ledger 2.', '']
    ip = f'{OUT}/README.md'
    itext = '\n'.join(index)
    if check:
        if not os.path.exists(ip) or open(ip).read() != itext:
            bad.append(ip)
    else:
        open(ip, 'w').write(itext)

    if check:
        print('reference drift check:',
              ', '.join(bad) + ' DIFFER' if bad else '  every page matches the ledger and source')
        return 1 if bad else 0
    print(f'generated {len(AREAS)+1} reference pages covering {len(L)} symbols')
    return 0


sys.exit(main())
