"""Isolated recovery/ordering tests. No production hooks, accounts or signals."""
import contextlib
import importlib.util
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
BRIDGE = ROOT/'script/agent_signal_bridge.py'
spec = importlib.util.spec_from_file_location('bridge_recovery_checks',BRIDGE)
bridge = importlib.util.module_from_spec(spec);spec.loader.exec_module(bridge)

# Run the actual hook main. Its stdin read is held AFTER begin_attempt, making
# late failure/early-success interleavings deterministic across real processes.
DELAYED_MAIN = r'''
import importlib.util,json,os,sys,time
from pathlib import Path
source,directory,ready,release,kind=sys.argv[1:]
spec=importlib.util.spec_from_file_location('delayed_bridge',source)
bridge=importlib.util.module_from_spec(spec);spec.loader.exec_module(bridge)
class Input:
    @property
    def buffer(self):return self
    def read(self,limit):
        fd=os.open(ready,os.O_WRONLY|os.O_CREAT|os.O_EXCL,0o600)
        os.write(fd,b'ready');os.close(fd)
        deadline=time.monotonic()+5
        while not Path(release).exists():
            if time.monotonic()>deadline:raise RuntimeError('synthetic barrier timeout')
            time.sleep(0.005)
        if kind=='failure':return b'{'
        return json.dumps({'session_id':'recovery-synthetic','hook_event_name':'UserPromptSubmit','turn_id':'delayed-success'}).encode()
sys.argv=[source,'--source','codex','--directory',directory]
sys.stdin=Input()
raise SystemExit(bridge.main())
'''


class RecoveryChecks(unittest.TestCase):
    def setUp(self):
        base=ROOT/'.build/ux-v36/bridge-recovery/tests'
        if any(p.is_symlink() for p in [base,*base.parents]):raise RuntimeError('Unsafe owned test directory')
        base.mkdir(parents=True,exist_ok=True,mode=0o700)
        self.temporary=tempfile.TemporaryDirectory(dir=base)
        self.root=Path(self.temporary.name);self.directory=self.root/'signals'
        self.children=[]
    def tearDown(self):
        for child in self.children:
            if child.poll() is None:
                child.terminate()
                try:child.wait(timeout=1)
                except subprocess.TimeoutExpired:child.kill();child.wait(timeout=1)
        self.temporary.cleanup()
    def payload(self,turn='one',event='UserPromptSubmit'):
        return {'session_id':'recovery-synthetic','hook_event_name':event,'turn_id':turn,
                'prompt':'SYNTHETIC_PRIVATE_PROMPT','transcript_path':'/SYNTHETIC_PRIVATE_PATH'}
    def hook(self,payload,source='codex',input_format='hook'):
        data=payload if isinstance(payload,bytes) else json.dumps(payload).encode()
        result=subprocess.run([sys.executable,str(BRIDGE),'--source',source,'--format',input_format,'--directory',str(self.directory)],input=data,capture_output=True,timeout=3)
        self.assertEqual((result.returncode,result.stdout,result.stderr),(0,b'{}\n',b''))
        return result
    def in_process_main(self,payload):
        stream=io.TextIOWrapper(io.BytesIO(json.dumps(payload).encode()))
        output,error=io.StringIO(),io.StringIO()
        with mock.patch.object(sys,'argv',[str(BRIDGE),'--source','codex','--directory',str(self.directory)]),mock.patch.object(sys,'stdin',stream),contextlib.redirect_stdout(output),contextlib.redirect_stderr(error):
            result=bridge.main()
        self.assertEqual((result,output.getvalue(),error.getvalue()),(0,'{}\n',''))
    def marker(self):return self.directory/'bridge-error.json'
    def mark(self):
        self.hook(b'{')
        self.assertTrue(self.marker().exists())
        return self.marker().read_bytes()
    def publications(self):
        return tuple((self.directory/name).read_bytes() for name in ['state.json','inbox.json'])
    def valid_publication(self):
        state=bridge.private_read(self.directory/'state.json');inbox=bridge.private_read(self.directory/'inbox.json')
        bridge.validate_state(state);bridge.validate_inbox(inbox)
        self.assertEqual(inbox,bridge.inbox_for_state(state))
    def child(self,kind):
        ready=self.root/('ready-'+str(len(self.children)));release=self.root/('go-'+str(len(self.children)))
        child=subprocess.Popen([sys.executable,'-c',DELAYED_MAIN,str(BRIDGE),str(self.directory),str(ready),str(release),kind],stdout=subprocess.PIPE,stderr=subprocess.PIPE)
        self.children.append(child)
        deadline=time.monotonic()+3
        while not ready.exists():
            if child.poll() is not None:raise AssertionError('Child stopped before controlled barrier')
            if time.monotonic()>deadline:raise AssertionError('Child did not reach controlled barrier')
            time.sleep(0.005)
        return child,release
    def release(self,child,path):
        fd=os.open(path,os.O_WRONLY|os.O_CREAT|os.O_EXCL,0o600);os.close(fd)
        out,err=child.communicate(timeout=3)
        self.assertEqual((child.returncode,out,err),(0,b'{}\n',b''))

    def test_valid_hook_clears_a_prior_verified_error_after_complete_publication(self):
        self.mark();self.hook(self.payload())
        self.assertFalse(self.marker().exists());self.valid_publication()
        for path in self.directory.iterdir():
            self.assertEqual(path.stat().st_mode&0o777,0o600)
            self.assertNotIn(b'SYNTHETIC_PRIVATE',path.read_bytes())

    def test_legacy_marker_without_new_fields_is_recoverable(self):
        bridge.private_directory(self.directory,create=True)
        bridge.atomic_write(self.marker(),{'schemaVersion':1,'code':'bridge_failed','at':100})
        self.hook(self.payload());self.assertFalse(self.marker().exists());self.valid_publication()

    def test_ignored_hook_and_duplicate_do_not_claim_recovery(self):
        self.hook(self.payload());self.mark();before=self.publications();marker=self.marker().read_bytes()
        self.hook(self.payload(event='PostToolUse'))
        self.assertEqual((self.publications(),self.marker().read_bytes()),(before,marker))
        self.hook(self.payload())
        self.assertEqual((self.publications(),self.marker().read_bytes()),(before,marker))

    def test_corrupt_state_remains_unknown_and_is_not_overwritten(self):
        self.hook(self.payload());self.mark()
        state=self.directory/'state.json';state.write_bytes(b'{SYNTHETIC_CORRUPT_STATE');state.chmod(0o600)
        inbox=(self.directory/'inbox.json').read_bytes()
        self.hook(self.payload('two'))
        self.assertTrue(self.marker().exists());self.assertEqual(state.read_bytes(),b'{SYNTHETIC_CORRUPT_STATE')
        self.assertEqual((self.directory/'inbox.json').read_bytes(),inbox)

    def test_corrupt_inbox_stays_unknown_until_explicit_fixture_repair(self):
        self.hook(self.payload());before=self.publications()
        inbox=self.directory/'inbox.json';inbox.write_bytes(b'{SYNTHETIC_CORRUPT_INBOX');inbox.chmod(0o600)
        self.hook(self.payload('two'))
        self.assertTrue(self.marker().exists());self.assertEqual(inbox.read_bytes(),b'{SYNTHETIC_CORRUPT_INBOX')
        self.assertEqual((self.directory/'state.json').read_bytes(),before[0])
        inbox.write_bytes(before[1]);inbox.chmod(0o600)
        self.hook(self.payload('three'));self.assertFalse(self.marker().exists());self.valid_publication()

    def test_corrupt_or_foreign_error_marker_is_never_overwritten_or_removed(self):
        for value in [b'{',b'{"schemaVersion":99,"code":"bridge_failed","at":1}',b'{"schemaVersion":1,"code":"other","at":1}',b'{"schemaVersion":true,"code":"bridge_failed","at":1}',b'{"schemaVersion":1,"code":"bridge_failed","at":1,"body":"SYNTHETIC_PRIVATE"}']:
            with self.subTest(value=value):
                self.hook(self.payload('seed'))
                # A separate subtest uses the same path only after explicitly
                # removing its own prior synthetic malformed marker.
                self.marker().write_bytes(value);self.marker().chmod(0o600)
                before=self.publications()
                self.hook(self.payload('new'))
                self.assertEqual(self.marker().read_bytes(),value);self.assertEqual(self.publications(),before)
                self.marker().unlink()

    def test_error_symlink_is_left_in_place_and_external_target_is_unchanged(self):
        self.hook(self.payload());before=self.publications()
        outside=self.root/'external';outside.write_bytes(b'external synthetic');outside.chmod(0o600)
        self.marker().symlink_to(outside);self.hook(self.payload('two'))
        self.assertTrue(self.marker().is_symlink());self.assertEqual(outside.read_bytes(),b'external synthetic');self.assertEqual(self.publications(),before)

    def test_error_hardlink_is_left_in_place_and_external_target_is_unchanged(self):
        self.hook(self.payload());before=self.publications()
        outside=self.root/'external';outside.write_bytes(b'{"schemaVersion":1,"code":"bridge_failed","at":1}');outside.chmod(0o600)
        original=outside.read_bytes();os.link(outside,self.marker());self.hook(self.payload('two'))
        self.assertEqual(outside.read_bytes(),original);self.assertEqual(outside.stat().st_nlink,2);self.assertTrue(self.marker().exists());self.assertEqual(self.publications(),before)

    def test_error_permissions_are_not_repaired_or_bypassed(self):
        self.hook(self.payload());value=self.mark();self.marker().chmod(0o644);before=self.publications()
        self.hook(self.payload('two'))
        self.assertEqual((self.marker().read_bytes(),self.marker().stat().st_mode&0o777),(value,0o644));self.assertEqual(self.publications(),before)

    def test_error_owner_mismatch_is_rejected_without_mutation(self):
        self.hook(self.payload());value=self.mark();owner=os.getuid()
        with mock.patch.object(bridge.os,'getuid',return_value=owner+1):
            with self.assertRaises(bridge.BridgeError):bridge.error_snapshot(self.directory)
        self.assertEqual(self.marker().read_bytes(),value)

    def test_nonregular_error_marker_does_not_block_or_get_removed(self):
        self.hook(self.payload());before=self.publications();os.mkfifo(self.marker(),0o600)
        self.hook(self.payload('two'));self.assertTrue(self.marker().exists());self.assertEqual(self.publications(),before)

    def test_partial_publish_records_failure_before_unlock_and_next_valid_hook_recovers(self):
        self.hook(self.payload());before_inbox=(self.directory/'inbox.json').read_bytes();original=bridge.atomic_write
        def fail_inbox(path,value):
            if path.name=='inbox.json':raise bridge.BridgeError('synthetic_inbox_failure')
            return original(path,value)
        with mock.patch.object(bridge,'atomic_write',side_effect=fail_inbox):self.in_process_main(self.payload('two'))
        self.assertTrue(self.marker().exists());self.assertEqual((self.directory/'inbox.json').read_bytes(),before_inbox)
        self.hook(self.payload('three'));self.assertFalse(self.marker().exists());self.valid_publication()

    def test_unconfirmed_readback_does_not_clear_a_prior_error(self):
        self.hook(self.payload());self.mark();original=bridge.private_read;reads=0
        def wrong_readback(path,missing=None):
            nonlocal reads
            value=original(path,missing)
            if path.name=='state.json':
                reads+=1
                if reads==2:return bridge.initial_state()
            return value
        with mock.patch.object(bridge,'private_read',side_effect=wrong_readback):self.in_process_main(self.payload('two'))
        self.assertTrue(self.marker().exists());self.valid_publication()
        self.hook(self.payload('three'));self.assertFalse(self.marker().exists())

    def test_old_failure_arriving_after_success_does_not_resurrect_unknown(self):
        self.hook(self.payload());child,release=self.child('failure')
        self.hook(self.payload('new-success'));before=self.publications()
        self.release(child,release)
        self.assertFalse(self.marker().exists());self.assertEqual(self.publications(),before);self.valid_publication()

    def test_early_success_cannot_clear_a_newer_failure_then_fresh_success_can(self):
        self.hook(self.payload());self.mark();child,release=self.child('success')
        latest=self.mark();self.release(child,release)
        self.assertEqual(self.marker().read_bytes(),latest);self.valid_publication()
        self.hook(self.payload('fresh-success'));self.assertFalse(self.marker().exists());self.valid_publication()

    def test_old_failure_does_not_replace_a_newer_error_marker(self):
        self.hook(self.payload());self.mark();child,release=self.child('failure')
        latest=self.mark();self.release(child,release)
        self.assertEqual(self.marker().read_bytes(),latest)

    def test_state_only_partial_write_is_not_proof_to_suppress_a_failure(self):
        self.hook(self.payload());attempt=bridge.begin_attempt(self.directory)
        state=bridge.private_read(self.directory/'state.json');state['sequence']+=1
        bridge.atomic_write(self.directory/'state.json',state)
        self.assertTrue(bridge.record_failure(self.directory,attempt));self.assertTrue(self.marker().exists())

    def test_corrupt_new_pair_is_not_proof_to_suppress_a_failure(self):
        self.hook(self.payload());attempt=bridge.begin_attempt(self.directory)
        state=bridge.private_read(self.directory/'state.json');bridge.atomic_write(self.directory/'state.json',state)
        bridge.atomic_write(self.directory/'inbox.json',{'schemaVersion':1,'events':[],'completionProposedCount':0,'private':'SYNTHETIC_PRIVATE'})
        self.assertTrue(bridge.record_failure(self.directory,attempt));self.assertTrue(self.marker().exists())

    def test_notify_is_only_stop_proposed_and_can_recover_a_prior_error(self):
        self.mark()
        self.hook({'type':'agent-turn-complete','thread-id':'recovery-synthetic','turn-id':'notify'},input_format='notify')
        self.assertFalse(self.marker().exists());self.valid_publication()
        self.assertEqual(bridge.private_read(self.directory/'inbox.json')['events'][0]['state'],'stopProposed')


if __name__=='__main__':unittest.main()
