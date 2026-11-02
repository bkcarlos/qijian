#!/usr/bin/env python3
"""Read-only smoke test. Reads the private token file without logging the token.

Does not save household data to disk. Pass --details to print names and capabilities.
"""
import argparse
import json
import pathlib
import urllib.request
import urllib.error
import uuid

parser = argparse.ArgumentParser()
parser.add_argument('--token-file', type=pathlib.Path, default=pathlib.Path(__file__).resolve().parent.parent / 'work/.homekit-mcp/access.token')
parser.add_argument('--details', action='store_true')
args = parser.parse_args()
try:
    token = args.token_file.read_text().strip()
except OSError as error:
    raise SystemExit('无法读取客户端令牌。请在 App 中“导出客户端凭据”到项目 work 目录，或用 --token-file 指定导出的文件。(' + error.strerror + ')')
endpoint = 'http://127.0.0.1:18765/mcp'
headers = {'Authorization': 'Bearer ' + token, 'Content-Type': 'application/json',
           'Accept': 'application/json, text/event-stream', 'MCP-Protocol-Version': '2025-06-18'}
counter = 0

def expect_http_error(status, overrides):
    changed = dict(headers)
    changed.update(overrides)
    req = urllib.request.Request(endpoint, data=b'{"jsonrpc":"2.0","id":1,"method":"ping"}', headers=changed)
    try:
        urllib.request.urlopen(req, timeout=12)
    except urllib.error.HTTPError as error:
        assert error.code == status, (status, error.code)
    else:
        raise AssertionError('Expected HTTP rejection ' + str(status))

expect_http_error(401, {'Authorization': 'Bearer wrong-token'})
expect_http_error(403, {'Origin': 'https://untrusted.example'})
expect_http_error(403, {'Host': 'untrusted.example:18765'})
print('HTTP access controls: PASS (token, Origin, Host)')

def rpc(method, params=None, notification=False):
    global counter
    counter += 1
    body = {'jsonrpc': '2.0', 'method': method}
    if not notification:
        body['id'] = counter
    if params is not None:
        body['params'] = params
    request = urllib.request.Request(endpoint, data=json.dumps(body).encode(), headers=headers)
    with urllib.request.urlopen(request, timeout=12) as response:
        raw = response.read()
        if notification:
            assert response.status == 202 and not raw
            return None
        value = json.loads(raw)
        assert value.get('id') == counter
        assert 'error' not in value, value.get('error')
        return value['result']

def call(name, arguments=None):
    result = rpc('tools/call', {'name': name, 'arguments': arguments or {}})
    if result.get('isError'):
        raise RuntimeError(result.get('structuredContent'))
    return result['structuredContent']

print('initialize:', rpc('initialize', {'protocolVersion': '2025-06-18', 'capabilities': {}, 'clientInfo': {'name': 'readonly-verifier', 'version': '1.0'}})['serverInfo'])
rpc('notifications/initialized', notification=True)
tools = rpc('tools/list')['tools']
assert len(tools) == 10 and all(t['annotations']['readOnlyHint'] for t in tools)
print('read-only tools:', ', '.join(t['name'] for t in tools))
status = call('get_status')
print('authorization:', status['authorization'], 'loaded:', status['loaded'])
if status['authorization'] != 'authorized' or not status['loaded']:
    raise SystemExit('App is running; HomeKit authorization/data still required.')
homes = call('list_homes')['homes']
rooms = call('list_rooms')['rooms']
devices = call('list_accessories')['accessories']
scenes = call('list_scenes')['scenes']
print('counts:', {'homes': len(homes), 'rooms': len(rooms), 'accessories': len(devices), 'scenes': len(scenes)})
if args.details:
    print(json.dumps({'homes': homes, 'rooms': rooms, 'accessories': devices, 'scenes': scenes}, ensure_ascii=False, indent=2))
for device in devices:
    capability = call('get_accessory_capabilities', {'accessory_id': device['id']})['accessory']
    assert 'services' in capability
    if args.details and '插线板' in device['name']:
        print('power_strip_capabilities:', json.dumps(capability, ensure_ascii=False, indent=2))
for scene in scenes:
    detail = call('get_scene', {'scene_id': scene['id']})['scene']
    assert len(detail['actions']) == detail['actionCount']
if homes:
    preview = call('preview_change', {'tool': 'create_room', 'arguments': {'home_id': homes[0]['id'], 'name': 'MCP preview ' + str(uuid.uuid4())[:8]}})
    assert preview['valid'] and preview['submitted'] is False
# Invalid target as a second guard: this can never rename a real home, even if
# someone accidentally runs this read-only verifier with a control credential.
denied = rpc('tools/call', {'name': 'rename_home', 'arguments': {'home_id': 'verification-nonexistent-target', 'name': 'Do not apply', 'request_id': str(uuid.uuid4())}})
assert denied['isError'] and denied['structuredContent']['code'] == 'read_only_credential'
print('Mutation boundary: PASS (preview only; read credential rejects writes)')
print('PASS: enumerated HomeKit topology and capabilities without device writes.')
