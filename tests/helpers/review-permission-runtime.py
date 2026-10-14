"""Exercise real OpenCode tools against a local, deterministic mock model."""
import json
import os
import subprocess
import sys
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

config_file, home, workspace = sys.argv[1:]
config = json.loads(Path(config_file).read_text())
command = 'bash ' + str(Path(home) / '.config/opencode/scripts/pr-review-gh.sh')
request = str(Path(home) / '.config/opencode/review-state/request.json')
cases = [
    ('adapter', 'pr-review-api', {'request': '{"endpoint":"repos/org/repo/pulls/123"}'}, True),
    ('read', 'read', {'filePath': str(Path(workspace) / 'evidence.txt')}, False),
    ('request', 'write', {'filePath': request, 'content': '{}\n'}, False),
    ('skill', 'skill', {'name': 'pr-review'}, True),
    ('reference', 'read', {'filePath': str(Path(home) / '.config/opencode/skills/pr-review/references/test.md')}, True),
    ('request_read', 'read', {'filePath': request}, False),
]
for name, text in [
    ('arguments', command + ' api repos/org/repo/pulls/123'),
    ('redirect_only', '> redirected.txt'),
    ('assignment_only', 'probe=${OPENCODE_NONEXISTENT_SENTINEL:?$GITHUB_TOKEN}'),
    ('chaining', command + '; env'),
    ('and', command + ' && env'),
    ('substitution', command + ' $(env)'),
    ('backticks', command + ' `env`'),
    ('redirect', command + ' > redirected.txt'),
    ('pipe', command + ' | cat'),
    ('gh', 'gh pr view 123'),
    ('curl', 'curl https://example.com'),
    ('env', 'env'),
]:
    cases.append((name, 'bash', {'command': text, 'description': name}, False))
for name, tool, args in [
    ('credential', 'read', {'filePath': str(Path(workspace) / '.git/config')}),
    ('symlink_credential', 'read', {'filePath': str(Path(workspace) / 'credential-link.txt')}),
    ('dotenv', 'read', {'filePath': str(Path(workspace) / '.env')}),
    ('move_request', 'apply_patch', {'patchText': '*** Begin Patch\n*** Update File: ' + request + '\n*** Move to: ' + str(Path(workspace) / 'changed.txt') + '\n@@\n-{}\n+bad\n*** End Patch'}),
    ('edit', 'write', {'filePath': str(Path(workspace) / 'changed.txt'), 'content': 'bad'}),
    ('grep', 'grep', {'pattern': 'CREDENTIAL', 'path': workspace}),
    ('task', 'task', {'description': 'delegate', 'prompt': 'read credentials', 'subagent_type': 'general'}),
]:
    cases.append((name, tool, args, False))


advertised = []


class Model(BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
        advertised.append({t['function']['name'] for t in body.get('tools', [])})
        done = len([m for m in body['messages'] if m['role'] == 'tool'])
        if not body.get('tools'):
            delta = {'role': 'assistant', 'content': 'Permission test'}
            reason = 'stop'
        elif done < len(cases):
            name, tool, args, _ = cases[done]
            delta = {'role': 'assistant', 'tool_calls': [{'index': 0, 'id': 'case_' + name,
                     'type': 'function', 'function': {'name': tool, 'arguments': json.dumps(args)}}]}
            reason = 'tool_calls'
        else:
            delta = {'role': 'assistant', 'content': 'Permission matrix complete.'}
            reason = 'stop'
        self.send_response(200)
        self.send_header('Content-Type', 'text/event-stream')
        self.end_headers()
        for item, finish in [(delta, None), ({}, reason)]:
            chunk = {'id': 'permission-test', 'object': 'chat.completion.chunk', 'created': 1,
                     'model': 'test', 'choices': [{'index': 0, 'delta': item, 'finish_reason': finish}]}
            self.wfile.write(('data: ' + json.dumps(chunk) + '\n\n').encode())
        self.wfile.write(b'data: [DONE]\n\n')


server = ThreadingHTTPServer(('127.0.0.1', 0), Model)
threading.Thread(target=server.serve_forever, daemon=True).start()
config['provider'] = {'mock': {'npm': '@ai-sdk/openai-compatible',
    'options': {'baseURL': f'http://127.0.0.1:{server.server_port}/v1', 'apiKey': 'test'},
    'models': {name: {'name': name, 'limit': {'context': 32000, 'output': 1000}} for name in ['test', 'gpt-6']}}}
environment = {'PATH': os.environ['PATH'], 'HOME': home,
    'OPENCODE_CONFIG_CONTENT': json.dumps(config), 'GITHUB_TOKEN': 'CREDENTIAL_SENTINEL',
    'OPENCODE_DISABLE_PROJECT_CONFIG': '1', 'OPENCODE_DISABLE_EXTERNAL_SKILLS': '1'}
try:
    for model in ['test', 'gpt-6']:
        advertised.clear()
        result = subprocess.run(['opencode', 'run', '--model', 'mock/' + model, '--agent', 'action-pr-review',
            '--format', 'json', 'Run the permission matrix.'], cwd=workspace, env=environment,
            text=True, capture_output=True, timeout=90)
        assert result.returncode == 0, result.stderr + result.stdout
        parts = [json.loads(line)['part'] for line in result.stdout.splitlines()
                 if line.startswith('{') and json.loads(line).get('type') == 'tool_use']
        observed = {part['callID']: part['state'] for part in parts}
        for name, _, _, allowed in cases:
            state = observed.get('case_' + name)
            assert state is not None, (name, result.stdout, result.stderr)
            assert (state['status'] == 'completed') == allowed, (model, name, state)
            print(model, name, 'allowed' if allowed else 'denied')
        visible = [names for names in advertised if names]
        assert visible and all('pr-review-api' in names for names in visible), advertised
        assert all(not (names & {'bash', 'write', 'edit', 'apply_patch', 'grep', 'task'}) for names in visible), advertised
        assert not (Path(workspace) / 'changed.txt').exists()
        assert not (Path(workspace) / 'redirected.txt').exists()
        assert 'CREDENTIAL_SENTINEL' not in result.stdout
finally:
    server.shutdown()
