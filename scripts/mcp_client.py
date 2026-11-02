#!/usr/bin/env python3
"""Local HTTP MCP client. Never logs credentials or retries mutations automatically."""
import argparse
import json
from pathlib import Path
import sys
import time
import urllib.error
import urllib.request
import uuid

ROOT = Path(__file__).resolve().parent.parent

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--control', action='store_true', help='Use the separately exported control credential')
    parser.add_argument('--token-file', type=Path)
    parser.add_argument('--wait', type=float, default=0, help='Poll operation completion for up to this many seconds; never resubmits')
    sub = parser.add_subparsers(dest='command', required=True)
    sub.add_parser('tools')
    call_parser = sub.add_parser('call')
    call_parser.add_argument('tool')
    group = call_parser.add_mutually_exclusive_group()
    group.add_argument('--args', default='{}', help='JSON object, quoted for your shell')
    group.add_argument('--args-file', type=Path, help='Read tool arguments from a JSON file')
    options = parser.parse_args()
    token_file = options.token_file or ROOT / 'work/.homekit-mcp' / ('control.token' if options.control else 'access.token')
    try:
        token = token_file.read_text().strip()
    except OSError:
        parser.error('Credential unavailable. Export the appropriate credential from the Mac app to the project work directory.')
    headers = {'Authorization': 'Bearer ' + token, 'Content-Type': 'application/json', 'Accept': 'application/json, text/event-stream', 'MCP-Protocol-Version': '2025-06-18'}
    counter = 0

    def rpc(method, params=None, notification=False):
        nonlocal counter
        counter += 1
        body = {'jsonrpc': '2.0', 'method': method}
        if params is not None:
            body['params'] = params
        if not notification:
            body['id'] = counter
        request = urllib.request.Request('http://127.0.0.1:18765/mcp', data=json.dumps(body).encode(), headers=headers)
        with urllib.request.urlopen(request, timeout=65) as response:
            if notification:
                if response.status != 202:
                    raise RuntimeError('Unexpected notification status')
                return None
            value = json.load(response)
        if value.get('id') != counter or 'error' in value:
            raise RuntimeError('JSON-RPC error: ' + json.dumps(value.get('error', {})))
        return value['result']

    rpc('initialize', {'protocolVersion': '2025-06-18', 'capabilities': {}, 'clientInfo': {'name': 'homekit-http-cli', 'version': '0.2.0'}})
    rpc('notifications/initialized', notification=True)
    tools = rpc('tools/list')['tools']
    if options.command == 'tools':
        print(json.dumps(tools, ensure_ascii=False, indent=2))
        return 0
    definition = next((t for t in tools if t['name'] == options.tool), None)
    if definition is None:
        parser.error('Tool is not available to this credential. Use tools to inspect its scope.')
    arguments = json.loads(options.args_file.read_text() if options.args_file else options.args)
    if not isinstance(arguments, dict):
        parser.error('Arguments must be a JSON object')
    if not definition['annotations']['readOnlyHint']:
        arguments.setdefault('request_id', str(uuid.uuid4()))
        # Print the recovery key before sending; a broken connection is not proof of failure.
        print('Mutation request_id: ' + str(arguments['request_id']), file=sys.stderr)
    result = rpc('tools/call', {'name': options.tool, 'arguments': arguments})
    receipt = result.get('structuredContent', {})
    deadline = time.monotonic() + max(0, options.wait)
    while not result.get('isError') and receipt.get('state') == 'running' and time.monotonic() < deadline:
        time.sleep(min(0.5, max(0, deadline - time.monotonic())))
        result = rpc('tools/call', {'name': 'get_operation', 'arguments': {'request_id': receipt['request_id']}})
        receipt = result.get('structuredContent', {})
    print(json.dumps(result, ensure_ascii=False, indent=2))
    return 1 if result.get('isError') or receipt.get('state') in ['failed', 'partial_failure', 'outcome_unknown'] else (2 if receipt.get('state') == 'running' else 0)

if __name__ == '__main__':
    try:
        sys.exit(main())
    except (OSError, ValueError, RuntimeError) as error:
        print('Request failed: ' + str(error) + '. A failed connection does not prove a mutation failed; query get_operation using its request_id.', file=sys.stderr)
        sys.exit(1)
