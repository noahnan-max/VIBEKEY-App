#!/usr/bin/env python3
"""Observational local hooks. No transcript reads, decisions, network or config writes."""
import argparse
from contextlib import contextmanager
import fcntl
import hashlib
import json
import math
import os
from pathlib import Path
import re
import shlex
import stat
import sys
import time
import uuid

MAX_BYTES = 2 * 1024 * 1024
MAX_SESSIONS = 4096
DEFAULT_DIRECTORY = Path.home() / 'Library/Application Support/Vibekey/AgentSignals'
EVENTS = {'running', 'approvalRequired', 'attentionRequired', 'stopProposed', 'turnCompleted', 'failed', 'ended'}
IDENTIFIER = re.compile(r'\A[A-Za-z0-9_.:-]{1,256}\Z')
KNOWN_HOOKS = {'SessionStart','SessionEnd','UserPromptSubmit','Stop','StopFailure','TaskCompleted','PermissionRequest','Notification','PreToolUse','PostToolUse','SubagentStart','SubagentStop','Interrupt','PreCompact','PostCompact'}


class BridgeError(Exception):
    pass


def digest(*values):
    return hashlib.sha256('\0'.join(values).encode('utf-8')).hexdigest()


def private_directory(directory, create=False):
    directory = Path(os.path.abspath(directory))
    for path in [directory, *directory.parents]:
        if path.is_symlink():
            raise BridgeError('unsafe_path')
    if create:
        directory.mkdir(parents=True, exist_ok=True, mode=0o700)
    info = directory.stat()
    if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid() or stat.S_IMODE(info.st_mode) != 0o700:
        raise BridgeError('private_directory_required')
    return directory


def private_read(path, missing=None):
    try:
        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC | os.O_NONBLOCK)
    except FileNotFoundError:
        return missing
    try:
        info = os.fstat(fd)
        if not stat.S_ISREG(info.st_mode) or info.st_nlink != 1 or info.st_uid != os.getuid() or stat.S_IMODE(info.st_mode) != 0o600 or info.st_size > MAX_BYTES:
            raise BridgeError('unsafe_file')
        with os.fdopen(fd, 'rb', closefd=False) as stream:
            data = stream.read(MAX_BYTES + 1)
        if len(data) > MAX_BYTES:
            raise BridgeError('oversize_file')
        return json.loads(data)
    finally:
        os.close(fd)


def atomic_write(path, value):
    data = json.dumps(value, ensure_ascii=True, sort_keys=True, separators=(',', ':')).encode()
    if len(data) > MAX_BYTES:
        raise BridgeError('oversize_file')
    if path.is_symlink():
        raise BridgeError('unsafe_file')
    if path.exists():
        info = path.stat()
        if not stat.S_ISREG(info.st_mode) or info.st_nlink != 1 or info.st_uid != os.getuid() or stat.S_IMODE(info.st_mode) != 0o600:
            raise BridgeError('unsafe_file')
    temporary = path.parent / ('.signal-' + uuid.uuid4().hex)
    fd = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW | os.O_CLOEXEC, 0o600)
    try:
        with os.fdopen(fd, 'wb', closefd=False) as output:
            output.write(data); output.flush(); os.fsync(fd)
        os.replace(temporary, path)
    finally:
        os.close(fd)
        if temporary.exists():
            temporary.unlink()


def file_version(path):
    """Metadata only; never follow a publication path to another file."""
    try:
        info = path.lstat()
    except FileNotFoundError:
        return None
    return (info.st_dev, info.st_ino, info.st_mode, info.st_uid, info.st_nlink,
            info.st_size, info.st_mtime_ns, info.st_ctime_ns)


def publication_version(directory):
    return (file_version(directory/'state.json'), file_version(directory/'inbox.json'))


@contextmanager
def bridge_lock(directory, create=False):
    directory = private_directory(directory, create=create)
    path = directory/'.bridge.lock'
    fd = os.open(path, os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW | os.O_CLOEXEC | os.O_NONBLOCK, 0o600)
    try:
        info = os.fstat(fd)
        if not stat.S_ISREG(info.st_mode) or info.st_nlink != 1 or info.st_uid != os.getuid() or stat.S_IMODE(info.st_mode) != 0o600:
            raise BridgeError('unsafe_lock')
        deadline = time.monotonic() + 0.5
        while True:
            try:
                fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB); break
            except BlockingIOError:
                if time.monotonic() >= deadline: raise BridgeError('bridge_busy')
                time.sleep(0.005)
        named = path.lstat()
        if named.st_dev != info.st_dev or named.st_ino != info.st_ino:
            raise BridgeError('lock_path_changed')
        yield directory
    finally:
        os.close(fd)


def error_snapshot(directory):
    path = directory/'bridge-error.json'
    version = file_version(path)
    if version is None:
        return None
    value = private_read(path)
    if (not isinstance(value,dict) or set(value) != {'schemaVersion','code','at'}
        or type(value['schemaVersion']) is not int or value['schemaVersion'] != 1
        or value['code'] != 'bridge_failed' or type(value['at']) not in (int,float)
        or not math.isfinite(value['at']) or value['at'] <= 0):
        raise BridgeError('invalid_error_marker')
    if file_version(path) != version:
        raise BridgeError('error_path_changed')
    return (version, value)


def begin_attempt(directory):
    # Capture before reading/parsing stdin. A slow failure must not resurrect an
    # error after another invocation has successfully published a newer batch.
    with bridge_lock(directory, create=True) as owned:
        return {'publication':publication_version(owned),
                'error':error_snapshot(owned), 'failure_recorded':False}


def write_error_locked(directory):
    # Unknown/corrupt files are not ours to replace, even if the path is private.
    error_snapshot(directory)
    atomic_write(directory/'bridge-error.json',
                 {'schemaVersion':1,'code':'bridge_failed','at':time.time()})


def record_failure(directory, attempt=None):
    if attempt is not None and attempt['failure_recorded']:
        return False
    with bridge_lock(directory) as owned:
        current_error = error_snapshot(owned)
        if attempt is not None and current_error is not None and current_error != attempt['error']:
            return False
        if attempt is not None and newer_complete_publication(owned, attempt['publication']):
            return False
        write_error_locked(owned)
        if attempt is not None: attempt['failure_recorded'] = True
        return True


def clear_recovered_error(directory, attempt):
    # All cooperating success/error writers hold this same lock. Clear only the
    # precise valid marker observed when this invocation began, never a newer
    # failure that arrived while it was waiting or decoding its input.
    if attempt['error'] is not None and error_snapshot(directory) == attempt['error']:
        (directory/'bridge-error.json').unlink()
        return True
    return False


def safe_id(value):
    return value if isinstance(value, str) and IDENTIFIER.fullmatch(value) else None


def normalize(source, payload, input_format='hook'):
    if not isinstance(payload, dict) or source not in ('codex', 'claude'):
        raise BridgeError('invalid_payload')
    if input_format == 'notify':
        if source != 'codex' or payload.get('type') != 'agent-turn-complete':
            return None, 'unsupported_event'
        session, turn, kind = payload.get('thread-id'), payload.get('turn-id'), 'agent-turn-complete'
        # Legacy notify is emitted before post-turn compaction, which can still
        # fail or be interrupted. It is a proposal, not strict completion.
        state = 'stopProposed'
    else:
        session, turn, kind = payload.get('session_id'), payload.get('turn_id'), payload.get('hook_event_name')
        if kind == 'TaskCompleted':
            # This hook runs before a task is committed completed and another
            # hook may veto it. Never promote this proposal to a green signal.
            return None, 'completion_proposed'
        if kind == 'SessionStart':
            state = None
        else:
            mapping = {'UserPromptSubmit':'running', 'PermissionRequest':'approvalRequired',
                       'Stop':'stopProposed', 'SessionEnd':'ended'}
            if source == 'codex':
                mapping['Interrupt'] = 'attentionRequired'
            else:
                mapping['StopFailure'] = 'failed'
            state = mapping.get(kind)
            if source == 'claude' and kind == 'Notification':
                state = {'permission_prompt':'approvalRequired','idle_prompt':'attentionRequired',
                         'elicitation_dialog':'attentionRequired'}.get(payload.get('notification_type'))
            if state is None:
                return None, 'unsupported_event'
            if kind == 'Stop' and payload.get('stop_hook_active') is not False:
                return None, 'stop_continuation_or_unknown'
    session = safe_id(session)
    if session is None:
        raise BridgeError('invalid_session_identity')
    agent = safe_id(payload.get('agent_id')) or ''
    base = digest(source, session, agent)
    # Hashes only stable metadata; never hash prompt/message/tool_input for IDs.
    return {'source':source,'base':base,'kind':kind,'state':state,'turn':safe_id(turn),
            'upstreamID':safe_id(payload.get('event_id'))}, None


def initial_state():
    return {'schemaVersion':1,'sequence':0,'sessions':{},'retired':[],'diagnostics':{}}


def hash_value(value):
    return isinstance(value,str) and re.fullmatch('[0-9a-f]{64}',value) is not None


def validate_event(value):
    expected={'schemaVersion','source','state','sessionHash','eventID','sequence','occurredAt','simulation'}
    if not isinstance(value,dict) or not expected.issubset(value) or not set(value).issubset(expected|{'turnHash'}) or type(value['schemaVersion']) is not int or value['schemaVersion']!=1 or value['source'] not in ('codex','claude') or value['state'] not in EVENTS or value['simulation'] is not False:
        raise BridgeError('invalid_state_event')
    if 'turnHash' in value and not hash_value(value['turnHash']): raise BridgeError('invalid_state_event')
    if not hash_value(value['sessionHash']) or not hash_value(value['eventID']) or type(value['sequence']) is not int or value['sequence']<=0 or type(value['occurredAt']) not in (int,float) or not math.isfinite(value['occurredAt']) or value['occurredAt']<=0:
        raise BridgeError('invalid_state_event')


def validate_inbox(value):
    if (not isinstance(value,dict) or set(value) != {'schemaVersion','events','completionProposedCount'}
        or type(value['schemaVersion']) is not int or value['schemaVersion'] != 1
        or not isinstance(value['events'],list) or len(value['events']) > MAX_SESSIONS * 2
        or type(value['completionProposedCount']) is not int or value['completionProposedCount'] < 0):
        raise BridgeError('invalid_inbox')
    for event in value['events']: validate_event(event)


def inbox_for_state(state):
    events = list(state['retired'])
    for row in state['sessions'].values():
        events.extend(row['pending'])
        if row['latest']: events.append(row['latest'])
    unique = {value['eventID']:value for value in events}
    return {'schemaVersion':1,'events':sorted(unique.values(),key=lambda x:x['sequence']),
            'completionProposedCount':state['diagnostics'].get('completionProposed',0)}


def newer_complete_publication(directory, previous):
    current = publication_version(directory)
    # A state-only partial write is not evidence of a later successful publish.
    if any(now is None or now == old for now,old in zip(current,previous)):
        return False
    try:
        state = private_read(directory/'state.json')
        inbox = private_read(directory/'inbox.json')
        validate_state(state);validate_inbox(inbox)
        return inbox == inbox_for_state(state)
    except Exception:
        return False


def validate_state(state):
    if not isinstance(state,dict) or set(state)!={'schemaVersion','sequence','sessions','retired','diagnostics'} or type(state['schemaVersion']) is not int or state['schemaVersion']!=1 or type(state['sequence']) is not int or state['sequence']<0:
        raise BridgeError('invalid_state')
    if not isinstance(state['sessions'],dict) or not isinstance(state['retired'],list) or len(state['sessions'])+len(state['retired'])>MAX_SESSIONS:
        raise BridgeError('invalid_state')
    if not isinstance(state['diagnostics'],dict) or not set(state['diagnostics']).issubset({'completionProposed'}) or any(type(x) is not int or x<0 for x in state['diagnostics'].values()):
        raise BridgeError('invalid_state')
    for value in state['retired']:
        validate_event(value)
        if value['state']!='ended':raise BridgeError('invalid_tombstone')
    for key,row in state['sessions'].items():
        if not hash_value(key) or not isinstance(row,dict) or set(row)!={'epoch','latest','pending','seen','startID','ended'} or type(row['epoch']) is not int or row['epoch']<0 or type(row['ended']) is not bool:
            raise BridgeError('invalid_state_row')
        if row['latest'] is not None:validate_event(row['latest'])
        if row['ended'] and (not row['latest'] or row['latest']['state']!='ended'):raise BridgeError('invalid_tombstone')
        if row['startID'] is not None and not hash_value(row['startID']):raise BridgeError('invalid_state_row')
        if not isinstance(row['seen'],list) or len(row['seen'])>64 or not all(hash_value(x) for x in row['seen']):raise BridgeError('invalid_state_row')
        if not isinstance(row['pending'],list) or len(row['pending'])>16:raise BridgeError('invalid_state_row')
        for value in row['pending']:
            validate_event(value)
            if value['state']!='approvalRequired':raise BridgeError('invalid_state_row')


def ingest(directory, source, payload, input_format='hook', now=None, _attempt=None):
    attempt = begin_attempt(directory) if _attempt is None else _attempt
    received = time.time() if now is None else now
    if not isinstance(received, (int,float)) or not math.isfinite(received) or received <= 0:
        raise BridgeError('invalid_time')
    event, ignored = normalize(source, payload, input_format)
    with bridge_lock(directory) as directory:
        try:
            state = private_read(directory / 'state.json', initial_state())
            validate_state(state)
            prior_inbox = private_read(directory / 'inbox.json')
            if prior_inbox is not None: validate_inbox(prior_inbox)
            error_snapshot(directory)
            if ignored:
                if ignored == 'completion_proposed':
                    state['diagnostics']['completionProposed'] = min(2**31-1, state['diagnostics'].get('completionProposed',0)+1)
                else:
                    return {'status':'IGNORED','reason':ignored}
            else:
                base = event['base']; row = state['sessions'].get(base)
                if row is None:
                    if len(state['sessions']) + len(state['retired']) >= MAX_SESSIONS: raise BridgeError('capacity_exceeded')
                    row = {'epoch':0,'latest':None,'pending':[],'seen':[],'startID':None,'ended':False}
                if event['kind'] == 'SessionStart':
                    if row['ended']:
                        if len(state['sessions']) + len(state['retired']) >= MAX_SESSIONS: raise BridgeError('capacity_exceeded')
                        state['retired'].append(row['latest'])
                        row = {'epoch':row['epoch']+1,'latest':None,'pending':[],'seen':[],'startID':None,'ended':False}
                    state['sessions'][base] = row
                else:
                    if row['ended']: return {'status':'IGNORED','reason':'ended_session'}
                    turn_marker = digest(source, base, event['turn']) if event['turn'] else None
                    if event['kind'] == 'UserPromptSubmit':
                        row['startID'] = turn_marker or digest(base, 'start', str(state['sequence']+1))
                    elif source == 'codex' and turn_marker and row['startID'] and row['startID'] != turn_marker:
                        return {'status':'IGNORED','reason':'different_turn'}
                    # Stop is a pre-commit proposal: another matching hook may
                    # require continuation even when stop_hook_active is false.
                    if event['state'] in ('stopProposed','turnCompleted') and row['startID'] is None and input_format != 'notify':
                        return {'status':'IGNORED','reason':'start_not_observed'}
                    session_hash = digest(base, str(row['epoch']))
                    # Neither current official PermissionRequest contract exposes
                    # a request/tool ID. Distinct deliveries in one turn must not
                    # be falsely merged. The consumer marks these uncorrelated and
                    # anchors their TTL to the first pending receipt. Never infer
                    # resolution from PostToolUse, tool names or arguments.
                    if event['state'] == 'approvalRequired':
                        token = event['upstreamID'] or ('uncorrelated:'+uuid.uuid4().hex)
                    else:
                        token = event['upstreamID'] or event['turn'] or row['startID'] or str(state['sequence']+1)
                    event_id = digest(source, session_hash, event['kind'], token)
                    if event_id in row['seen']: return {'status':'IGNORED','reason':'duplicate'}
                    if row['latest'] and received < row['latest']['occurredAt']: return {'status':'IGNORED','reason':'old_time'}
                    state['sequence'] += 1
                    value = {'schemaVersion':1,'source':source,'state':event['state'],'sessionHash':session_hash,
                             'eventID':event_id,'sequence':state['sequence'],'occurredAt':received,'simulation':False}
                    if turn_marker: value['turnHash'] = turn_marker
                    row['latest'] = value
                    row['seen'] = (row['seen'] + [event_id])[-64:]
                    if event['state'] == 'approvalRequired':
                        if len(row['pending']) >= 16: raise BridgeError('approval_capacity')
                        row['pending'].append(value)
                    if event['state'] == 'ended': row['ended'] = True; row['pending'] = []
                    state['sessions'][base] = row
            inbox = inbox_for_state(state)
            if len(inbox['events']) > MAX_SESSIONS * 2: raise BridgeError('event_capacity')
            # A crash between these private atomic writes may delay visibility, but
            # it cannot stamp an old event fresh. The next hook republishes state.
            validate_state(state)
            validate_inbox(inbox)
            atomic_write(directory / 'state.json', state)
            atomic_write(directory / 'inbox.json', inbox)
            published_state = private_read(directory / 'state.json')
            published_inbox = private_read(directory / 'inbox.json')
            validate_state(published_state)
            validate_inbox(published_inbox)
            if published_state != state or published_inbox != inbox:
                raise BridgeError('publication_readback_failed')
            clear_recovered_error(directory, attempt)
            return {'status':'IGNORED' if ignored else 'RECORDED','reason':ignored}
        except Exception:
            # This transaction may already have replaced state.json. Record its
            # failure before releasing the lock; a later success may then heal
            # that exact marker. Main must not publish this failure a second time.
            attempt['failure_recorded'] = True
            try: write_error_locked(directory)
            except Exception: pass
            raise


def config_summary(path):
    result = {'path':str(path),'exists':path.exists(),'symlink':path.is_symlink()}
    if not path.exists() or any(p.is_symlink() for p in [path,*path.parents]): return result
    data = path.read_bytes()
    result.update(bytes=len(data),sha256=hashlib.sha256(data).hexdigest())
    if len(data) > MAX_BYTES: result['parseStatus']='OVERSIZE';return result
    try:
        if path.suffix == '.toml':
            try: import tomllib
            except ImportError: import tomli as tomllib
            content = tomllib.loads(data.decode())
        else: content = json.loads(data)
        hooks = content.get('hooks',{})
        result['hookGroups'] = {name:len(groups) for name,groups in hooks.items() if name in KNOWN_HOOKS and isinstance(groups,list)} if isinstance(hooks,dict) else {}
        result['handlerCount'] = sum(len(group.get('hooks',[])) for groups in hooks.values() if isinstance(groups,list) for group in groups if isinstance(group,dict) and isinstance(group.get('hooks',[]),list)) if isinstance(hooks,dict) else None
        result['notifyConfigured'] = isinstance(content.get('notify'),list) and bool(content['notify'])
        result['disableAllHooks'] = content.get('disableAllHooks') if type(content.get('disableAllHooks')) is bool else 'unspecified'
        feature = content.get('features',{}).get('hooks','unspecified')
        result['hooksFeature'] = feature if type(feature) is bool else 'unspecified'
    except Exception: result['parseStatus']='UNAVAILABLE'
    return result


def plan(directory, python=sys.executable):
    script = str(Path(__file__).resolve())
    plans = []
    for source, path in [('codex',Path.home()/'.codex/hooks.json'),('claude',Path.home()/'.claude/settings.json')]:
        names = ['SessionStart','UserPromptSubmit','PermissionRequest','Stop','SessionEnd']
        if source == 'codex': names += ['Interrupt']
        else: names += ['StopFailure','Notification']
        command = shlex.join([python,script,'--source',source,'--directory',str(directory)])
        additions = {}
        for name in names:
            group = {'hooks':[{'type':'command','command':command,'timeout':3}]}
            if name == 'Notification': group['matcher']='permission_prompt|idle_prompt|elicitation_dialog'
            additions[name] = [group]
        plans.append({'source':source,'target':str(path),'existing':config_summary(path),'appendGroups':additions,
                      'mergeRule':'Append these groups to each existing hooks[event] array; preserve every old group, handler and other field. Do not replace notify or any existing configuration.',
                      'trust':'Codex /hooks review and trust required; never bypass or write trust hashes.' if source=='codex' else 'Current Claude docs: settings watcher normally reloads hooks. Verify /hooks; if missed, normal session restart is required. No permission decision is emitted.'})
    return {'schemaVersion':1,'status':'PLAN_ONLY_NOT_INSTALLED','directory':str(directory),'plans':plans,
            'codexInlineConfig':config_summary(Path.home()/'.codex/config.toml'),
            'desktopSupport':'Official local Codex hooks documented; actual desktop loading and events NOT_RUN',
            'realTaskCompleted':'UNSUPPORTED: TaskCompleted is pre-commit and may be vetoed',
            'approvalResolution':'UNAVAILABLE: current PermissionRequest contracts lack a request/tool ID. Preserve uncorrelated receipts as needs-review; no PostToolUse heuristic. Only explicit SessionEnd clears these receipts.',
            'rawFieldsPersisted':False,'globalConfigurationWritten':False}


class SafeParser(argparse.ArgumentParser):
    def error(self, message):
        raise BridgeError('invalid_arguments')


def main():
    parser = SafeParser(description=__doc__)
    parser.add_argument('--source',choices=['codex','claude'])
    parser.add_argument('--format',choices=['hook','notify'],default='hook')
    parser.add_argument('--directory',type=Path,default=DEFAULT_DIRECTORY)
    parser.add_argument('--plan',action='store_true')
    parser.add_argument('notify_payload',nargs='?')
    directory = None
    attempt = None
    try:
        args = parser.parse_args();directory=args.directory
        if args.plan:
            print(json.dumps(plan(args.directory),ensure_ascii=False,indent=2));return 0
        attempt = begin_attempt(args.directory)
        if not args.source: raise BridgeError('missing_source')
        data = args.notify_payload.encode() if args.notify_payload is not None else sys.stdin.buffer.read(MAX_BYTES+1)
        if len(data)>MAX_BYTES: raise BridgeError('oversize_input')
        ingest(args.directory,args.source,json.loads(data),args.format,_attempt=attempt)
    except Exception:
        # Static failure marker only. Never echo an exception that may contain a
        # prompt, command, raw payload or credential. Never block an agent hook.
        if directory is not None:
            try:
                record_failure(directory, attempt)
            except Exception: pass
    print('{}')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
