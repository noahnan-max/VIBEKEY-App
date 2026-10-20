import importlib.util
import json
import os
from pathlib import Path
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('agent_signal_bridge', ROOT/'script/agent_signal_bridge.py')
bridge = importlib.util.module_from_spec(spec)
spec.loader.exec_module(bridge)


class BridgeChecks(unittest.TestCase):
    def setUp(self):
        base=ROOT/'.build/ux-v35/agent-signals-python'
        base.mkdir(parents=True,exist_ok=True,mode=0o700)
        self.temporary=tempfile.TemporaryDirectory(dir=base)
        self.directory=Path(self.temporary.name)/'inbox'
    def tearDown(self): self.temporary.cleanup()
    def payload(self,event,**values):
        return dict(session_id='synthetic-session',hook_event_name=event,prompt='PRIVATE_PROMPT_MUST_NOT_PERSIST',
                    last_assistant_message='PRIVATE_REPLY_MUST_NOT_PERSIST',transcript_path='/PRIVATE_TRANSCRIPT_PATH',
                    tool_input={'password':'PRIVATE_ARGUMENT_MUST_NOT_PERSIST'},**values)
    def emit(self,event,source='codex',now=100,**values):
        return bridge.ingest(self.directory,source,self.payload(event,**values),now=now)
    def inbox(self): return json.loads((self.directory/'inbox.json').read_text())
    def test_no_raw_content_or_paths_persist(self):
        self.emit('UserPromptSubmit',turn_id='turn-1')
        self.emit('PermissionRequest',now=101,turn_id='turn-1')
        for path in self.directory.iterdir():
            data=path.read_bytes()
            self.assertNotIn(b'PRIVATE_',data)
            self.assertEqual(path.stat().st_mode & 0o777,0o600)
        self.assertEqual(self.directory.stat().st_mode & 0o777,0o700)
    def test_stop_is_precommit_proposal_for_both_agents(self):
        for source in ('codex','claude'):
            self.emit('UserPromptSubmit',source=source,turn_id='turn-1')
            self.emit('Stop',source=source,now=101,turn_id='turn-1',stop_hook_active=False)
        self.assertEqual([e['state'] for e in self.inbox()['events']],['stopProposed','stopProposed'])
    def test_other_hook_can_continue_after_first_stop(self):
        self.emit('UserPromptSubmit',turn_id='turn-1')
        self.emit('Stop',now=101,turn_id='turn-1',stop_hook_active=False)
        self.assertNotIn('turnCompleted',[e['state'] for e in self.inbox()['events']])
        self.emit('UserPromptSubmit',now=102,turn_id='continuation-2')
        self.assertEqual(self.inbox()['events'][-1]['state'],'running')
    def test_stop_without_observed_start_or_continuation_does_not_complete(self):
        self.assertEqual(self.emit('Stop',stop_hook_active=False)['reason'],'start_not_observed')
        self.emit('UserPromptSubmit',turn_id='turn-1')
        self.assertEqual(self.emit('Stop',now=101,turn_id='turn-1',stop_hook_active=True)['reason'],'stop_continuation_or_unknown')
    def test_task_completed_is_proposal_even_with_completed_text(self):
        self.emit('UserPromptSubmit',source='claude')
        self.emit('TaskCompleted',source='claude',now=101,task_id='task-1',status='completed')
        inbox=self.inbox()
        self.assertEqual(inbox['completionProposedCount'],1)
        self.assertEqual([e['state'] for e in inbox['events']],['running'])
    def test_unrelated_tool_completion_does_not_clear_approval(self):
        self.emit('UserPromptSubmit',turn_id='turn-1')
        self.emit('PermissionRequest',now=101,turn_id='turn-1')
        self.assertEqual(self.emit('PostToolUse',now=102,turn_id='turn-1',tool_use_id='other-tool')['reason'],'unsupported_event')
        self.emit('Stop',now=103,turn_id='turn-1',stop_hook_active=False)
        self.assertEqual([e['state'] for e in self.inbox()['events']],['approvalRequired','stopProposed'])
    def test_two_uncorrelated_approvals_in_one_turn_are_not_merged(self):
        for source in ('codex','claude'):
            with self.subTest(source=source):
                self.emit('UserPromptSubmit',source=source,turn_id='one-turn')
                self.emit('PermissionRequest',source=source,now=101,turn_id='one-turn')
                self.emit('PermissionRequest',source=source,now=102,turn_id='one-turn')
                approvals=[e for e in self.inbox()['events'] if e['source']==source and e['state']=='approvalRequired']
                self.assertEqual(len(approvals),2)
                self.assertNotEqual(approvals[0]['eventID'],approvals[1]['eventID'])
                self.assertTrue(all('requestHash' not in e for e in approvals))
    def test_unproven_request_ids_and_post_tool_failure_do_not_resolve(self):
        self.emit('UserPromptSubmit',source='claude')
        self.emit('PermissionRequest',source='claude',now=101,tool_use_id='unsupported-match',request_id='unsupported-match')
        self.assertEqual(self.emit('PostToolUseFailure',source='claude',now=102,tool_use_id='unsupported-match')['reason'],'unsupported_event')
        self.assertEqual(self.emit('PermissionResolved',source='claude',now=103,request_id='unsupported-match')['reason'],'unsupported_event')
        self.assertEqual([e['state'] for e in self.inbox()['events']],['approvalRequired'])
    def test_explicit_event_duplicate_is_not_restamped(self):
        self.emit('UserPromptSubmit',turn_id='turn-1')
        self.emit('PermissionRequest',now=101,turn_id='turn-1',event_id='fixture-event')
        before=(self.directory/'inbox.json').read_bytes()
        self.assertEqual(self.emit('PermissionRequest',now=105,turn_id='turn-1',event_id='fixture-event')['reason'],'duplicate')
        self.assertEqual(before,(self.directory/'inbox.json').read_bytes())
    def test_old_codex_turn_is_not_promoted(self):
        self.emit('UserPromptSubmit',turn_id='old')
        self.emit('UserPromptSubmit',now=101,turn_id='new')
        self.assertEqual(self.emit('Stop',now=102,turn_id='old',stop_hook_active=False)['reason'],'different_turn')
        self.assertEqual(self.inbox()['events'][-1]['state'],'running')
    def test_duplicate_stop_does_not_refresh_time(self):
        self.emit('UserPromptSubmit',turn_id='turn-1')
        self.emit('Stop',now=101,turn_id='turn-1',stop_hook_active=False)
        before=(self.directory/'inbox.json').read_bytes()
        self.assertEqual(self.emit('Stop',now=110,turn_id='turn-1',stop_hook_active=False)['reason'],'duplicate')
        self.assertEqual(before,(self.directory/'inbox.json').read_bytes())
    def test_ended_tombstone_and_explicit_new_epoch(self):
        self.emit('UserPromptSubmit',turn_id='turn-1')
        self.emit('SessionEnd',now=101)
        ended=self.inbox()['events'][-1]
        self.assertEqual(self.emit('Stop',now=102,turn_id='turn-1',stop_hook_active=False)['reason'],'ended_session')
        self.assertEqual(self.emit('UserPromptSubmit',now=103,turn_id='turn-2')['reason'],'ended_session')
        self.emit('SessionStart',now=104)
        self.emit('UserPromptSubmit',now=105,turn_id='turn-2')
        self.assertNotEqual(ended['sessionHash'],self.inbox()['events'][-1]['sessionHash'])
        self.assertIn(ended,self.inbox()['events'])
    def test_codex_notify_is_tentative_before_post_turn_work(self):
        result=bridge.ingest(self.directory,'codex',{'type':'agent-turn-complete','thread-id':'synthetic-notify','turn-id':'1','last-assistant-message':'PRIVATE_REPLY'},input_format='notify',now=100)
        self.assertEqual(result['status'],'RECORDED')
        self.assertEqual(self.inbox()['events'][0]['state'],'stopProposed')
    def test_claude_old_notification_whitelist_and_failure(self):
        self.emit('UserPromptSubmit',source='claude')
        self.emit('Notification',source='claude',now=101,notification_type='permission_prompt')
        self.assertEqual(self.inbox()['events'][-1]['state'],'approvalRequired')
        self.assertEqual(self.emit('Notification',source='claude',now=102,notification_type='agent_completed')['reason'],'unsupported_event')
        self.emit('StopFailure',source='claude',now=103,error='server_error')
        self.assertEqual([e['state'] for e in self.inbox()['events']],['approvalRequired','failed'])
    def test_bad_private_path_and_symlink_are_rejected(self):
        self.directory.mkdir(mode=0o755)
        with self.assertRaises(bridge.BridgeError):self.emit('UserPromptSubmit')
        self.directory.chmod(0o700)
        target=Path(self.temporary.name)/'target';target.write_text('{}');target.chmod(0o600)
        (self.directory/'state.json').symlink_to(target)
        with self.assertRaises(OSError):self.emit('UserPromptSubmit')
        self.assertEqual(target.read_text(),'{}')
    def test_fifo_state_rejected_without_blocking(self):
        self.directory.mkdir(mode=0o700)
        os.mkfifo(self.directory/'state.json',0o600)
        with self.assertRaises(bridge.BridgeError):self.emit('UserPromptSubmit')
    def test_boolean_schema_in_state_event_rejected(self):
        self.emit('UserPromptSubmit')
        state=json.loads((self.directory/'state.json').read_text())
        next(iter(state['sessions'].values()))['latest']['schemaVersion']=True
        (self.directory/'state.json').write_text(json.dumps(state));(self.directory/'state.json').chmod(0o600)
        with self.assertRaises(bridge.BridgeError):self.emit('PermissionRequest',now=101)
    def test_raw_extra_field_in_state_is_not_republished(self):
        self.emit('UserPromptSubmit')
        state=json.loads((self.directory/'state.json').read_text())
        next(iter(state['sessions'].values()))['prompt']='PRIVATE_CORRUPT_STATE'
        (self.directory/'state.json').write_text(json.dumps(state));(self.directory/'state.json').chmod(0o600)
        before=(self.directory/'inbox.json').read_bytes()
        with self.assertRaises(bridge.BridgeError):self.emit('PermissionRequest',now=101)
        self.assertEqual(before,(self.directory/'inbox.json').read_bytes())
    def test_plan_inspection_never_prints_existing_command(self):
        path=Path(self.temporary.name)/'settings.json'
        value={'hooks':{'Stop':[{'hooks':[{'type':'command','command':'PRIVATE_EXISTING_COMMAND'}]}]},'env':{'API_KEY':'PRIVATE_KEY'}}
        path.write_text(json.dumps(value));path.chmod(0o600)
        before=path.read_bytes();result=bridge.config_summary(path)
        self.assertEqual(result['handlerCount'],1)
        self.assertNotIn('PRIVATE_',json.dumps(result))
        self.assertEqual(path.read_bytes(),before)


if __name__=='__main__':unittest.main()
