#!/usr/bin/env python3
"""Opt-in macOS integration test: discover and execute only OCU's isolated fixture."""
import argparse
import json
import os
import subprocess
from pathlib import Path

repo = Path(__file__).resolve().parent.parent
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--native', type=Path, default=repo / '.build/debug/OpenComputerUse')
parser.add_argument('--config-file', type=Path, default=repo / '.build/intent-integration/config.json')
parser.add_argument('--with-app-agent', action='store_true', help='Test a newly built packaged runtime through its isolated App Agent')
parser.add_argument('--prepare', action='store_true', help='Open system template import without executing an Intent')
args = parser.parse_args()
environment = dict(os.environ, OPEN_COMPUTER_USE_CONFIG_FILE=str(args.config_file.resolve()),
                   OPEN_COMPUTER_USE_DISABLE_APP_AGENT_PROXY="0" if args.with_app_agent else "1",
                   OPEN_COMPUTER_USE_AGENT_SOCKET_NAMESPACE="ocu-intent-fixture-tests")
values = [dict(text='first runtime 参数', count=3, enabled=True, ratio=1.5),
          dict(text='second runtime 参数', count=9, enabled=False, ratio=2.25)]


def call(tool, arguments):
    result = subprocess.run([str(args.native.resolve()), 'call', tool, '--args', json.dumps(arguments)],
                            env=environment, stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=35)
    envelope = json.loads(result.stdout)
    message = next(item['text'] for item in envelope['content'] if item['type'] == 'text')
    response = json.loads(message)
    return response


catalog = call('list_intents', {'app': 'dev.ocu.IntentFixture'})
assert catalog['status'] == 'available', catalog
intent = next(item for item in catalog['intents'] if item['id'] == 'EchoParametersIntent')
assert intent['can_execute'], intent
parameters = {item['name']: item['type'] for item in intent['parameters']}
assert parameters == {'text': 'string', 'count': 'integer', 'enabled': 'boolean', 'ratio': 'number'}, parameters
if args.prepare:
    print(json.dumps(call('run_intent', {'app': 'dev.ocu.IntentFixture', 'action_id': intent['id'],
                                       'parameters': values[0], 'prepare': True}), ensure_ascii=False, indent=2))
else:
    print('Watch Shortcuts for app access or output approval. Adding the template does not grant output approval.', flush=True)
    for supplied in values:
        response = call('run_intent', {'app': 'dev.ocu.IntentFixture', 'action_id': intent['id'], 'parameters': supplied})
        if response['status'] == 'unknown':
            assert response['execution_started'] and not response['safe_to_fallback'], response
            print(json.dumps(response, ensure_ascii=False, indent=2), flush=True)
            raise SystemExit('Integration blocked: execution outcome is unknown. Check system prompts and the operation; no automatic retry was made.')
        assert response['status'] == 'completed', response
        assert json.loads(response['output']) == supplied, response
    print('Discovery and two executions with different runtime parameters passed.')
